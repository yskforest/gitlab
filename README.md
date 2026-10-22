# GitLab Docker

GitLab CE・HTTPS・Container RegistryをDocker Composeで起動します。Runnerは任意です。
必要環境はLinux、Bash、Docker Engine、Docker Compose（`up --wait`対応）、OpenSSL 1.1.1以降、curlです。
[GitLabのリソース要件](https://docs.gitlab.com/install/requirements/)を満たし、ポート80・443・2222・5050を空けてください。

## クイックリファレンス

リポジトリ内で、必要な操作だけ実行してください。以下は`gitlab.local`・Debian/Ubuntuの例です。

```bash
# 初回セットアップ（.envに hostname=gitlab.local を設定）
./setup.sh
sudoedit /etc/hosts  # DNSで解決できない場合は「127.0.0.1 gitlab.local」を追加
sudo cp .volumes/ssl/gitlab.local.crt /usr/local/share/ca-certificates/gitlab.local.crt
sudo update-ca-certificates

# 起動・初期パスワード確認（ユーザー名 root）
docker compose up -d --wait --wait-timeout 600
docker compose exec gitlab cat /etc/gitlab/initial_root_password

# 診断・状態・ログ（ログを追い続ける場合は -f を追加）
./setup.sh --check
docker compose ps -a
docker compose logs --tail=100 gitlab

# 停止 / 再開（データは .volumes に保持）
docker compose stop
docker compose up -d --wait --wait-timeout 600
```

接続先はGitLabが`https://gitlab.local`、Registryが`gitlab.local:5050`、SSHがポート`2222`です。
初回起動は数分かかります。タイムアウトした場合はログを確認してください。

## 設定・診断の補足

- ホスト名を変える場合は`.env`と各コマンドの`gitlab.local`を変更します。シェルの`hostname`環境変数が設定されている場合は、その値が優先されます。
- 別のPCから接続する場合は、hostsにサーバーのLAN IPを登録し、公開証明書（`.crt`）だけをコピーして信頼登録します。ブラウザによっては独自の証明書ストアにも登録が必要です。
- `setup.sh`は既存証明書のSAN・ホスト名・鍵の対応・期限（残り30日以上）を検査します。`--check`は設定・稼働状態・HTTPS・Registryを確認し、ファイル作成や起動は行いません。
- 診断は生成済み証明書を明示的に使うため、OS・ブラウザ・Dockerへの信頼登録は別途必要です。
- 権限エラー時は対象パスを確認してください。`.volumes/data`全体への再帰的な`chown`は、GitLab内部の所有権を壊す場合があります。
- 初期パスワードはログイン後に変更してください。初期パスワードファイルは初回起動から24時間後以降の再設定時に削除されます。

GitLab・Runnerのイメージタグは`latest`です。自己署名証明書を使用し、Let's Encryptは無効にしています。

## Container Registry

利用する各Dockerホストで証明書を登録します。Dockerの再起動は他のコンテナにも影響します。

```bash
sudo mkdir -p /etc/docker/certs.d/gitlab.local:5050
sudo cp .volumes/ssl/gitlab.local.crt /etc/docker/certs.d/gitlab.local:5050/ca.crt
sudo systemctl restart docker
docker login gitlab.local:5050
```

2要素認証を使う場合などは、必要な権限を持つアクセストークンで認証します。

## 証明書の更新

SANのない旧証明書や、期限の近い証明書を更新します。既存ファイルは`.volumes/ssl/backup.*`に退避されます。

```bash
./setup.sh --renew-cert
# 各PC・Dockerホストで新しい証明書を信頼登録してから反映
docker compose exec gitlab gitlab-ctl hup nginx
docker compose --profile ci restart gitlab-runner  # Runnerを利用している場合のみ
./setup.sh --check
```

## バックアップ

push・CIジョブなどの書き込みを止め、十分な空き容量を確保して実行します。
データに加えて、復元に必要な暗号化キー・設定・証明書と稼働バージョンを保存します。各コマンドの成功を確認してから次へ進んでください。

```bash
umask 077
backup_dir="$PWD/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"

# アプリケーションデータ
docker compose exec -T gitlab gitlab-backup create
sudo cp -a .volumes/data/backups "$backup_dir/application"

# 設定・秘密鍵・Runner登録情報
sudo tar -czf "$backup_dir/configuration.tar.gz" \
  .volumes/config .volumes/ssl .volumes/gitlab-runner
sudo chmod 600 "$backup_dir/configuration.tar.gz"
cp docker-compose.yml setup.sh "$backup_dir/"
docker compose config > "$backup_dir/compose.resolved.yml"
docker compose config --environment | sed -n '/^hostname=/p' > "$backup_dir/hostname.env"

# 実稼働バージョンとイメージ情報
docker compose exec -T gitlab cat /opt/gitlab/version-manifest.txt > "$backup_dir/version-manifest.txt"
container_id=$(docker compose ps -q gitlab)
image_id=$(docker inspect --format '{{.Image}}' "$container_id")
docker image inspect "$image_id" --format '{{json .RepoDigests}}' > "$backup_dir/image-digests.json"
```

`backups/`はGit管理対象外です。データは別ディスク等へ退避し、暗号化キーを含む`configuration.tar.gz`はアクセスを制限した保管先へ分けて保存してください。
保管期限・空き容量は手動で管理します。外部オブジェクトストレージを追加した場合、そのデータは別途バックアップが必要です。

## 復元

**空の復元先に、バックアップと完全に同じバージョン・CE版のGitLabを用意します。**
保存した`docker-compose.yml`・`setup.sh`を配置し、`hostname.env`を`.env`としてコピーしてください。
シェルの`hostname`環境変数による上書きにも注意します。

`version-manifest.txt`と`image-digests.json`を確認し、復元用の`restore-image.yml`を作成します。タグは保存した実際のCEバージョンに置き換えます。

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:<保存したCEバージョン>
```

次の変数を実際のパス・IDに置き換えて実行します。`backup_id`は`*_gitlab_backup.tar`から`_gitlab_backup.tar`を除いた部分です。

```bash
backup_dir=/path/to/backup
backup_id=バックアップID
sudo tar -xzf "$backup_dir/configuration.tar.gz"
mkdir -p .volumes/data/backups
sudo cp -a "$backup_dir/application/." .volumes/data/backups/

docker compose -f docker-compose.yml -f restore-image.yml up -d --wait --wait-timeout 600 gitlab
docker compose exec gitlab gitlab-ctl stop puma
docker compose exec gitlab gitlab-ctl stop sidekiq
docker compose exec gitlab gitlab-backup restore BACKUP="$backup_id"
docker compose exec gitlab gitlab-ctl reconfigure
docker compose restart gitlab
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
./setup.sh --check
```

復元確認までは、コンテナを作り直す操作で`-f restore-image.yml`を併用してください。
証明書の信頼登録、ログイン、clone、Registry、CIジョブを確認します。Runnerに記録されたホスト上の証明書パスも復元先に合わせてください。
詳しくは[公式の復元手順](https://docs.gitlab.com/administration/backup_restore/restore_gitlab/)を参照してください。

## Runner（任意）

同じLinuxホスト上で動かす構成です。通常起動ではRunnerは作成されません。
Dockerソケット経由でホストを操作できるため、信頼できるプロジェクト専用にしてください。

GitLabの管理画面・グループ・プロジェクトでRunnerを作成し、`glrt-`で始まる認証トークンを取得します。
タグなしジョブを実行する場合は、Runner側でも許可してください。

```bash
./setup.sh  # Runner用に公開証明書を配置
read -rsp 'Runner token: ' RUNNER_TOKEN
echo
docker compose --profile ci run --rm --no-deps gitlab-runner register \
  --non-interactive \
  --url https://gitlab.local \
  --token "$RUNNER_TOKEN" \
  --tls-ca-file /etc/gitlab-runner/certs/gitlab.local.crt \
  --executor docker \
  --docker-image alpine:latest \
  --docker-extra-hosts gitlab.local:host-gateway \
  --description local-docker-runner
unset RUNNER_TOKEN
docker compose --profile ci up -d gitlab-runner
docker compose --profile ci logs --tail=100 gitlab-runner
```

登録情報は`.volumes/gitlab-runner/config.toml`に保存されます。Runnerを含めた停止は`docker compose --profile ci stop`で行います。
ジョブ内のcurlなどでは必要に応じて`--cacert "$CI_SERVER_TLS_CA_FILE"`を指定します。Dockerビルド・pushには別途ジョブ用のDocker接続設定が必要です。
[自己署名証明書の公式設定](https://docs.gitlab.com/runner/configuration/tls-self-signed/)

動作確認用の`.gitlab-ci.yml`：

```yaml
smoke:
  image: alpine:latest
  script:
    - echo "Runner OK"
```

## Jenkins連携

- ローカルネットワークへWebhookを送る場合は、管理画面の「Settings → Network → Outbound requests」で接続先を許可します。
- Webhook URLは`http://<jenkins>/gitlab-webhook/`とし、Jenkins側と同じシークレットトークンを設定します。
- アクセストークンは、cloneなら`read_repository`、pushなら`write_repository`、API操作なら必要なAPI権限を付与します。Jenkins側にも名前解決・証明書の信頼設定が必要です。

## 開発時の検証

```bash
bash -n setup.sh
docker compose --profile ci config --quiet
python3 -m unittest discover -s tests -v
```

テストにはPython 3とDocker Compose CLIが必要です。一時ディレクトリで検証するため、Dockerデーモンや稼働中のGitLabは不要です。
