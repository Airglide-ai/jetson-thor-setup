# Tang server on Synology

Tang gives Clevis (on the Thor) what it needs to rebuild the key for the `DATA`
partition. It does not store the disk key: stealing the Tang server does not expose the
data. If the Thor leaves the network and cannot reach Tang, `DATA` does not unlock by itself.

## Requirements

- Synology with **Container Manager** (Package Center). If it is not listed, the model
  does not support Docker and Tang has to run on another machine.
- Fixed IP for the Synology (DHCP reservation or static IP).

## Install

1. In **File Station**, create the folder `docker/tang` and an empty `db/` inside it.
2. Upload the files in this folder to `docker/tang`: `Dockerfile`, `entrypoint.sh`,
   `compose.yaml`.
3. **Container Manager → Project → Create**
   - Name: `tang`
   - Path: `docker/tang`
   - Source: use the existing `compose.yaml`
4. Next → Done. It builds the image and starts the container.

On first start it generates the keys in `docker/tang/db/` (two `.jwk` files).

## Test

From the Thor or any machine on the network:

```bash
curl http://SYNOLOGY-IP:7500/adv
```

It must return JSON with `"payload"` and `"signatures"`.

## Security

- **Back up `docker/tang/db/`** (Hyper Backup). Without those keys the Thor will not
  unlock by itself and the backup passphrase is needed.
- Allow port `7500` **only from the Thor's IP**: rule on the Moxa firewall and,
  optionally, on the Synology (Control Panel → Security → Firewall).
- **Never** expose the port to the internet or through QuickConnect.
- Ideally the Synology is not in the same physical place as the Thor: if both are
  stolen, the protection is lost.

## Key rotation (optional)

1. Generate new keys in `db/` (`tangd-keygen`) and rename the old ones with a leading
   dot (`.xxxx.jwk`) so they keep working but are no longer advertised.
2. On the Thor: `sudo clevis luks regen -d /dev/disk/by-partlabel/DATA -s <slot>`.
3. Once every client has been regenerated, delete the old keys.
