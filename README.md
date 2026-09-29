# vm-migrate deployment

Automates moving a VM off Foreman's build network onto its production
subnet and updating its IP — replacing the manual workflow:

1. Assign an IP in phpIPAM → creates the A/PTR records in PowerDNS
2. Update the VM's network in Foreman → (in environments where the host
   is Compute-Resource-linked) Foreman pushes the change to the
   hypervisor
3. Change the VM's NIC bridge/VLAN tag directly via the Proxmox API —
   the moment this lands, the VM's old IP is unreachable
4. Push the new IP into the guest itself via `nmcli`, over the QEMU
   guest-agent channel (no SSH — that path is gone as of step 3) —
   opt-in per VM (`vm_migrate_guest_network_push`), since a mistake here
   is harder to recover from than the API-only steps above. Left off,
   this step reverts to the original manual workflow: log into the VM
   via the Proxmox console and fix its IP/connection info by hand.

Ad hoc, not a standing service — one VM per run, `--limit`-driven, same
shape as `deployments/proxmox-vm-manage`.

---

## Status (2026-09-28)

**Wired**, all phases:

- phpIPAM address assignment (`mgcdrd.infrasvc.phpipam_config`) — API-only
- Foreman host record update (`mgcdrd.infrasvc.foreman_host_network`) — API-only
- Proxmox NIC bridge/VLAN change (`mgcdrd.infrabase.proxmox_nic`) — API-only
- Guest-side network push via `mgcdrd.infrabase.proxmox_guest_exec` and
  `nmcli` — QEMU guest-agent channel, no SSH; opt-in per VM, see
  "Guest-side network push" below

**Unvalidated end-to-end.** This lab has no VLAN-tagged subnet and only
one Foreman subnet total, so the phpIPAM/Foreman/NIC phases above have
each been designed against real API schemas (introspected live,
2026-09-02) but not yet run against an actual migration in this lab. The
guest-side push is newer still (2026-09-28) and equally unrun against a
real VM — the `out-data` encoding assumption and the single-active-
nmcli-connection assumption it relies on (see "Guest-side network push")
are both unverified against a live guest. Test against a throwaway VM
before trusting any of this on anything real.

**Also found while wiring the guest push in:** `ansible.builtin.include_role`
combined with a task-level `delegate_to` is rejected outright by
ansible-core 2.19 ("'delegate_to' is not a valid attribute for a
IncludeRole") — this affected every phase in this file, not just the new
one, meaning `--syntax-check` had apparently never actually been run
against this deployment before. Fixed by switching every role invocation
in `site.yml` to `ansible.builtin.import_role` (static; accepts
`delegate_to` directly, and the `when:`/`vars:` gating this deployment
relies on works identically either way).

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
(`vm_migrate_new_ip`, `vm_migrate_proxmox_bridge`,
`vm_migrate_guest_network_push`) is defined/true for that host, so an
unscoped run is a no-op everywhere except a host that actually defines
them — `--limit` is for speed, not safety, same convention as
`deployments/proxmox-vm-manage`.

`qemu-guest-agent` must already be running in the guest before the
guest-side push phase can do anything (`mgcdrd.infrabase.qemu_guest_agent`
— this is what `harden`'s "Proxmox guest agent" phase applies). This
deployment has no way to install it itself — no SSH or console access,
only the QEMU guest-agent channel the agent itself provides.

---

## Guest-side network push

Opt-in via `vm_migrate_guest_network_push: true`, on its own trigger —
deliberately not implied by `vm_migrate_new_ip` alone, since a mistake
here can strand the VM with no network path except the Proxmox console,
unlike the API-only phases above.

Requires, in that VM's host_vars, alongside `vm_migrate_new_ip`:

- `vm_migrate_guest_os_family` — exactly `Debian` or `RedHat`. This play
  never gathers facts (no SSH), so there's no `ansible_facts['os_family']`
  to fall back on — it has to be declared.
- `vm_migrate_new_gateway`, `vm_migrate_new_dns` (list). The guest's IPv4
  prefix length reuses `vm_migrate_phpipam_subnet_mask`.
- `vm_migrate_new_dns_search` (list, optional) — DNS search domain(s).
  Defaults to `[domain]` (`inventory-common`'s env-wide domain) if unset,
  so a short hostname like `foreman` still resolves.
- `vm_migrate_guest_connection_name` (optional) — only needed if the
  guest has more than one active `nmcli` connection at push time.

**What it does**, in order: on Debian only, installs and enables
NetworkManager first (Proxmox's Debian cloud-init templates ship plain
`ifupdown`) — a `conf.d` drop-in sets `[ifupdown] managed=true` so NM
takes over the interface `/etc/network/interfaces` already defines,
rather than editing `NetworkManager.conf` in place (no `ini_file` module
available over a no-shell guest-exec call). RedHat skips this — ships
NetworkManager active already. Both families then: query the guest's
active `nmcli` connections and use the one match (or fail loud, listing
what it found, if there's more than one — set
`vm_migrate_guest_connection_name` to disambiguate); `nmcli connection
modify` that connection with the new address/gateway/DNS; `nmcli
connection up` to activate it.

**No `become:`.** `proxmox_guest_exec` has no connection plugin or
privilege-escalation layer — every command runs as whatever user
`qemu-guest-agent` executes commands as inside the guest (root, by
default).

**No automatic rollback.** If this phase fails partway (bootstrap
succeeded but the `nmcli modify`/`up` didn't, say), the VM may be left
with no working IPv4 config. Recovery is either re-running this phase
once the underlying problem is fixed, or the original manual Proxmox
console step — same fallback as before this phase existed.

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
  (not just recommended), since the guest-exec phase's role hard-asserts
  on token auth

---

## Client/customer delivery

Same shape as every other deployment here: point `ansible.cfg`'s
inventory path at the customer's own `inventory-<client>` repo, swap
`inventory/` overrides for their environment. The Compute-Resource
caveat above is the one thing worth re-checking per engagement — a
customer whose Foreman does own VM provisioning may get more out of
`foreman_host_network`'s `vlan_tag` field than this lab currently does.
