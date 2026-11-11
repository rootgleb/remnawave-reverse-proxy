# Форк: все протоколы ноды на 443

Отличия от eGamesAPI/remnawave-reverse-proxy только в установке ноды (nginx):

| Порт | Что слушает | Инбаунд |
|---|---|---|
| TCP 443 | xray VLESS raw + Vision + REALITY | `<tag>-vision` |
| `/dev/shm/xhttp.sock` | xray VLESS XHTTP + REALITY (фолбэк Vision) | `<tag>-xhttp` |
| `/dev/shm/nginx.sock` | nginx с настоящим сертификатом (фолбэк XHTTP): сайт-заглушка + gRPC-путь | — |
| `/dev/shm/grpc.sock` | xray VLESS gRPC, TLS снимает nginx | `<tag>-grpc` |
| UDP 443 | xray Hysteria2, тот же сертификат | `<tag>-hy2` |

`<tag>` — первая метка selfsteal-домена (`node3.example.com` → `node3`).

После установки:
- `/opt/remnanode/config.txt` — готовый профиль, вставить в панель целиком
  (Config profiles → + → вставить → сохранить → выбрать у ноды, отметить все 4 инбаунда);
- `/opt/remnanode/hosts.txt` — параметры хостов для клиентов.

Аутбаунды — только DIRECT и BLOCK, мосты добавляются вручную.

Ещё:
- в контейнер remnanode монтируется `/etc/letsencrypt` (сертификат для Hysteria2);
- хуки продления сертификата перезапускают и remnanode;
- открывается `443/udp`.

## Установка
```bash
bash <(curl -Ls https://raw.githubusercontent.com/rootgleb/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh)
```
