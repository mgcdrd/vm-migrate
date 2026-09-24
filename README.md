# vm-migrate deployment

Automates moving a VM off Foreman's build network onto its production
subnet and updating its IP — replacing the manual workflow:

1. Assign an IP in phpIPAM → creates the A/PTR records in PowerDNS
2. Update the VM's network in Foreman → (in environments where the host
   is Compute-Resource-linked) Foreman pushes the change to the
   hypervisor
3. Log into the VM via the Proxmox console to update its IP/connection
   info manually — needed because the moment step 2's VLAN change lands,
   the VM's old IP is unreachable and there's no network path in until
   the guest's own config is updated

Ad hoc, not a standing service — one VM per run, `--limit`-driven, same
shape as `deployments/proxmox-vm-manage`.

---

## Status (2026-09-02)

**Wired and working**, all API-only, no SSH to the target VM:

- phpIPAM address assignment (`mgcdrd.infrasvc.phpipam_config`)
- Foreman host record update (`mgcdrd.infrasvc.foreman_host_network`)
- Proxmox NIC bridge/VLAN change (`mgcdrd.infrabase.proxmox_nic`)

**Not wired in yet** — the piece that actually replaces step 3:

- Guest-side network config push via `mgcdrd.infrabase.proxmox_guest_exec`
  (built, but not yet called from `site.yml`). Needs the exact
  netplan (Debian) / nmcli (RedHat) approach settled — interface naming,
  file paths, and whether to fully replace the network config or patch
  the existing one — before it's safe to wire into a play that touches a
  live VM's IP. Track this down before relying on this deployment to
  fully replace the manual console step.

**Unvalidated end-to-end.** This lab has no VLAN-tagged subnet and only
one Foreman subnet total, so the phpIPAM/Foreman/NIC phases above have
each been designed against real API schemas (introspected live,
2026-09-02) but not yet run against an actual migration in this lab.
Test against a throwaway VM before trusting this on anything real.

---

## The Foreman Compute-Resource caveat

Foreman's "update the host, it pushes to the hypervisor" behavior only
fires for hosts it manages *as* a Compute Resource VM — that's how it
knows which VMID/node to call the Proxmox API against.

Checked live against this lab's Foreman: **none of its 28 hosts are
Compute-Resource-linked** (`provision_method: build`, null
`compute_resource_id`/`uuid` on every one) — VMs here are cloned directly
via `mgcdrd.infrabase.proxmox_vm` against the PVE API, not through
Foreman's own provisioning wizard. So in this lab, `foreman_host_network`
only keeps Foreman's own inventory record accurate — it does **not**
change anything on the hypervisor. That's why this deployment calls
`mgcdrd.infrabase.proxmox_nic` directly for the actual VLAN/bridge
change, rather than relying on Foreman to push it.

If a customer environment *does* provision VMs through Foreman's
Compute Resource flow, `foreman_host_network`'s `vlan_tag` field may
also propagate there — confirm `compute_resource_id`/`uuid` on the host
record before relying on that path alone. See
`mgcdrd.infrasvc.foreman_host_network`'s README for the full detail.

---

## Usage

```bash
ansible-galaxy collection install -r collections/requirements.yml
cp inventory/group_vars/all/env.yml.example inventory/group_vars/all/env.yml
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
cp inventory/host_vars/example.yml.example inventory/host_vars/<hostname>.yml
# edit both for your environment, then:
ansible-playbook site.yml --limit <hostname>
```

If the VM lives in an `inventory-common/instances/` directory (a k8s node, for
example), run `source ../../inventory-common/fleet-env.sh` first — otherwise
`--limit <hostname>` matches nothing.

Each phase in `site.yml` only runs if its trigger var
(`vm_migrate_new_ip`, `vm_migrate_proxmox_bridge`) is defined for that
host, so an unscoped run is a no-op everywhere except a host that
actually defines them — `--limit` is for speed, not safety, same
convention as `deployments/proxmox-vm-manage`.

---

## Vault

New credential paths, none populated yet as of 2026-09-02 — see
`inventory/group_vars/all/vault.yml.example` for the full lookup and what
each one needs:

- `infra/<env>/phpipam/api` — dedicated phpIPAM API user (`username`,
  `password`)
- `infra/<env>/foreman` — new `write_username`/`write_password` keys,
  dedicated identity scoped to Hosts edit (not the read-only
  `svc-ansible-inventory` identity, not an admin account)
- `infra/<env>/proxmox/api_token` — same secret
  `deployments/proxmox-vm-manage` documents minting; **required** here
  (not just recommended) once the guest-exec phase is wired in, since
  that role hard-asserts on token auth

---

## Client/customer delivery

Same shape as every other deployment here: point `ansible.cfg`'s
inventory path at the customer's own `inventory-<client>` repo, swap
`inventory/` overrides for their environment. The Compute-Resource
caveat above is the one thing worth re-checking per engagement — a
customer whose Foreman does own VM provisioning may get more out of
`foreman_host_network`'s `vlan_tag` field than this lab currently does.
