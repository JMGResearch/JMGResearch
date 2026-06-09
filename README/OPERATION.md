# Reset-Rollout — Operation Notes

This document describes the default Reset-Rollout two-USB workflow, paths, and how the pieces interact.

Defaults used by the committed scripts:
- Forensic certs directory (forensic device): /opt/reset-rollout/certs/
  - forensic-cert.pem (public cert)
  - forensic-key.pem (private key, protect carefully)
  - ca.pem (CA that issued attacker-trusted certs)
- Storage certs directory (storage appliance): /opt/reset-rollout/certs/
  - storage-cert.pem
  - storage-key.pem
  - ca.pem
- Work USB incoming mountpoint: /mnt/wdwork/incoming
- Final archive directory on storage appliance: /opt/storage/archives
- Allowed signer fingerprint list (storage): /etc/reset-rollout/allowed_signers.txt

High-level flow (local-only, no network):
1) Operator runs tools on forensic host. Files destined for long-term storage are staged with safe_stage_file. If WDDATA is read-only, staging occurs on the work USB or local WORK_DIR.
2) Staged files are automatically signed by the forensic device's private key and encrypted to the storage device's public cert (tools/encrypt_and_stage.sh). A .p7m and .meta are produced.
3) The encrypted artifact (.p7m) and its .meta are copied to the work USB incoming directory: /mnt/wdwork/incoming.
4) The storage appliance (storage_agent) runs the verify_and_store daemon which only accepts artifacts when INCOMING_DIR is mounted from a removable block device and the signer fingerprint is allow-listed in /etc/reset-rollout/allowed_signers.txt.
5) verify_and_store decrypts, verifies the signature, and moves the verified content into /opt/storage/archives. Unverified or incorrect artifacts are quarantined to /opt/storage/quarantine.

Security notes:
- Private keys MUST NOT be stored on the forensic read-only WDDATA. Protect keys with file permissions and consider hardware-backed storage.
- The storage appliance should run verify_and_store as an unprivileged user (storage_agent). The systemd unit includes network denial settings.
- No network transfer capabilities are included — only local copy to work USB is supported.

Files added in this branch:
- lib_common.sh (core helpers)
- tools/encrypt_and_stage.sh
- usr/local/bin/verify_and_store.sh
- etc/systemd/system/reset-rollout-verify.service
- README/OPERATION.md (this file)

Operational checklist (storage appliance):
- Create dedicated user:
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin storage_agent
- Create dirs and set ownership:
  sudo mkdir -p /opt/storage/archives /opt/storage/quarantine /mnt/wdwork/incoming
  sudo chown storage_agent:storage_agent /opt/storage/archives /opt/storage/quarantine
  sudo chmod 700 /opt/storage/archives /opt/storage/quarantine
- Place storage cert/key and CA under /opt/reset-rollout/certs/
- Populate /etc/reset-rollout/allowed_signers.txt with the forensic cert fingerprint (SHA256, uppercase, no colons)
- Install verify_and_store.sh to /usr/local/bin and enable the systemd unit:
  sudo cp usr/local/bin/verify_and_store.sh /usr/local/bin/
  sudo chmod 750 /usr/local/bin/verify_and_store.sh
  sudo chown root:storage_agent /usr/local/bin/verify_and_store.sh
  sudo cp etc/systemd/system/reset-rollout-verify.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now reset-rollout-verify.service

