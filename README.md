# GitLab docker

## env
- linux
- docker

## usage
以下のセットアップスクリプトを実行することで、必要なディレクトリの作成と自己署名SSL証明書の生成を自動で行います。

```bash
# スクリプトの実行（証明書の作成とディレクトリ作成）
./setup.sh
```

スクリプト実行後、画面に表示される案内に従って `/etc/hosts` の設定と証明書の信頼設定を行い、以下のコマンドで起動します。

```bash
docker compose up -d

# 初期管理者パスワードの確認
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

## http版
```yml
services:
  web:
    image: gitlab/gitlab-ce:latest
    container_name: 'gitlab'
    restart: always
    hostname: ${hostname}
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://${hostname}:8929'
        gitlab_rails['gitlab_shell_ssh_port'] = 2222
        nginx['listen_port'] = 80
        # Container Registry
        registry_external_url 'http://${hostname}:5050'
        registry['enable'] = true
    ports:
      - '8929:80'
      - '2222:22'
      - '5050:5050'
    volumes:
      - ./.volumes/config:/etc/gitlab
      - ./.volumes/logs:/var/log/gitlab
      - ./.volumes/data:/var/opt/gitlab
```

```bash
docker compose up -d

# check init pass
docker compose exec gitlab cat /etc/gitlab/initial_root_password
```

## 信頼済み証明書に追加
```bash
sudo cp gitlab.local.crt /usr/local/share/ca-certificates/gitlab.local.crt
sudo update-ca-certificates

# 証明書をDockerに信頼させる
sudo mkdir -p /etc/docker/certs.d/gitlab.local:5050
sudo cp ./.volumes/ssl/gitlab.local.crt /etc/docker/certs.d/gitlab.local:5050/ca.crt
sudo systemctl restart docker

# 証明書を変更した場合は実行する
docker exec -it gitlab gitlab-ctl reconfigure
```
## jenkins連携
### GitLab設定
- Webhook許可先の登録
  - ローカルネットワーク内でWebhookを投げたい時は、許可設定を入れる必要がある
  - Admin Area -> Settings -> Network -> Outbound requests
  - Allow requests to the local network from web hooks and servicesにチェックを入れるか、allow listに入れる
- Webwooks
  - プロジェクト
  - http://{jenkins}/gitlab-webhook/
- Access Tokensの発行
  - read_repository, api, write_repository

## memo
- [GitLabにPushしたソースコードをJenkinsで自動テストしてみる！](https://zenn.dev/alfredtiei/articles/45bac2eed5713c)
- runner接続
```
# GitLab 16.0以降では、Admin Area -> Runners からRunnerを事前に作成し、
# 発行された認証トークン（glrt-で始まるもの）を使用します。
gitlab-runner register \
  --non-interactive \
  --url https://gitlab.local \
  --token glrt-YOUR_AUTHENTICATION_TOKEN \
  --executor "docker" \
  --docker-image docker:cli
```
