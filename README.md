# Mist Switch Root Password (PowerShell)

Sets the local **root password** on Juniper Mist-managed EX switches, either one switch at a
time or many from a CSV file. You only need the switch's MAC address: the script looks the
switch up in the org inventory to find its site, so you never have to know or type the site.

The password is written as a **device-level override** (`switch_mgmt.root_password` on the
switch's own config). Any other `switch_mgmt` settings on that switch, and the rest of its
config, are left exactly as they were.

- [Requirements](#requirements)
- [Setup](#setup)
- [Mode 1 – a single switch](#mode-1--a-single-switch)
- [Mode 2 – many switches from a CSV file](#mode-2--many-switches-from-a-csv-file)
- [Dry run with -WhatIf](#dry-run-with--whatif)
- [Reading the results](#reading-the-results)
- [All parameters](#all-parameters)
- [How it works](#how-it-works)
- [Virtual Chassis](#virtual-chassis)
- [Password rules](#password-rules)
- [Proxy / Zscaler](#proxy--zscaler)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

---

## Requirements

- **PowerShell 7+** (Windows, macOS, Linux) or **Windows PowerShell 5.1**.
- A Mist **API token** with **write** access to the org (Org Admin, or Network Admin on the
  sites involved). Create one in the Mist portal under *My Account → API Token*, or as an
  org token under *Organization → Settings → API Token*.
- The switches must already be **claimed in the org and assigned to a site**.

## Setup

1. Download or clone this repo.
2. Copy the example settings file and fill it in:

   ```powershell
   Copy-Item mist_switch_root_password.ini.example mist_switch_root_password.ini
   ```

   ```ini
   [mist]
   cloud     = gc3
   api_token = your-api-token-here
   org_id    = 00000000-0000-0000-0000-000000000000
   ```

   | Key | Meaning |
   |---|---|
   | `cloud` | Your Mist cloud. Short name (`global01`, `gc3`, `eu`, `ac2` …) or the API / portal host (`api.gc3.mist.com`, `manage.gc3.mist.com`). The portal URL you log in to tells you which: `manage.mist.com` = `global01`, `manage.gc3.mist.com` = `gc3`, and so on. |
   | `api_token` | The API token. |
   | `org_id` | The org UUID (shown in the portal under *Organization → Settings*). |

   `cloud` and `org_id` can also be given on the command line with `-Cloud` and `-OrgId`,
   which is handy if you look after several orgs with one token.

3. On Windows, if script execution is blocked, allow it for the current window only:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   ```

By default the script reads `mist_switch_root_password.ini` from its own folder. Use
`-IniPath` to point at another file, e.g. one ini per customer.

---

## Mode 1 – a single switch

Give the MAC and the new password:

```powershell
./Set-MistSwitchRootPassword.ps1 -Mac 01:02:03:04:05:06 -Password 'mist12345'
```

The MAC can be written any way you like – these are all the same switch:

```
010203040506   01:02:03:04:05:06   01-02-03-04-05-06   0102.0304.0506
```

Always put the password in **single quotes** so PowerShell doesn't treat `$` or backticks
in it as special characters.

### Being prompted for the password

Leave out `-Password` and the script asks for it twice, with the typing hidden. This keeps
the password out of your shell history:

```powershell
./Set-MistSwitchRootPassword.ps1 -Mac 01:02:03:04:05:06
New root password: *********
Re-enter new root password: *********
```

### Example output

```
Mist API : https://api.gc3.mist.com/api/v1
Org      : PK Demo System

MAC               Switch        Site           Result  Note
---               ------        ----           ------  ----
01:02:03:04:05:06 EX4100_1_Edge _Demo_Site_001 UPDATED Did replace root_password (verified).

Summary: 1 switch(es) - UPDATED 1
```

---

## Mode 2 – many switches from a CSV file

Put one `mac,password` pair per line in a text file:

```csv
# Store 12 refresh - change window 06:00
mac,password
010203040506,N3w!Root#2026
01:02:03:04:05:07,An0ther$ecret
01-02-03-04-05-08,"Pass,with,commas"
```

Then run:

```powershell
./Set-MistSwitchRootPassword.ps1 -File .\switches.csv
```

File rules:

- The `mac,password` header line is optional.
- Blank lines and lines starting with `#` are ignored.
- Everything after the **first** comma is the password, so passwords may contain commas.
  Surrounding double quotes (as Excel adds) are removed.
- Each MAC may appear only once. If the same switch appears twice (in any MAC format) the
  script stops before changing anything and lists the duplicates.
- Every switch can have a different password.

`switches.csv.example` is a template. Real `.csv` files are git-ignored so passwords don't
end up in the repo.

Each switch is processed independently: a problem with one (bad MAC, not found, rejected
password) is recorded and the script carries on with the rest. A progress bar shows while it
works, and a summary table is printed at the end:

```
MAC               Switch        Site           Result    Note
---               ------        ----           ------    ----
01:02:03:04:05:06 EX4100_1_Edge _Demo_Site_001 UPDATED   Did replace root_password (verified).
01:02:03:04:05:07 EX4100_2_Edge _Demo_Site_001 UPDATED   Did add switch_mgmt with root_password (verified).
01:02:03:04:05:08 EX4000_1_Core _Demo_Site_001 UPDATED   VC member - set on VC 01:02:03:04:05:09. Did add switch_mgmt with root_password (verified).
aa:bb:cc:dd:ee:ff                              FAILED    MAC aa:bb:cc:dd:ee:ff not found in the org inventory.
01:02:03:04:05:0a                              FAILED    Password must be at least 6 characters (Junos minimum).

Summary: 5 switch(es) - FAILED 2, UPDATED 3
```

---

## Dry run with -WhatIf

Add `-WhatIf` to either mode. The script does all the lookups and checks but **writes
nothing**, and shows what it would do:

```powershell
./Set-MistSwitchRootPassword.ps1 -File .\switches.csv -WhatIf
```

```
Mode     : WhatIf - nothing will be written
What if: Performing the operation "replace root_password" on target "EX4100_1_Edge (01:02:03:04:05:06) at _Demo_Site_001".
...
01:02:03:04:05:06 EX4100_1_Edge _Demo_Site_001 WOULD CHANGE Would replace root_password.
```

Recommended for every batch: run with `-WhatIf` first, fix anything that shows `FAILED`,
then run again without it.

---

## Reading the results

| Result | Meaning |
|---|---|
| `UPDATED` | Password written and read back from Mist to confirm it. |
| `UNCHANGED` | The switch already has exactly this password override – nothing was sent. |
| `WOULD CHANGE` | `-WhatIf` run: this switch would be changed. |
| `FAILED` | Not changed. The *Note* column says why. |

The *Note* also tells you what kind of change was made:

- **replace root_password** – the switch already had a root password override.
- **add root_password to switch_mgmt** – the switch had other `switch_mgmt` overrides
  (e.g. `config_revert_timer`) but no password; those are kept.
- **add switch_mgmt with root_password** – the switch had no `switch_mgmt` overrides at all.

Warnings that can appear in the note:

- *Config management disabled on this switch* – the switch has *Disable Configuration
  Management* ticked in Mist, so Mist will not push the new password to it.
- *Switch is not Mist-configured (monitor only)* – the change is saved in Mist but won't
  reach the switch.

**Exit code:** `0` if nothing failed, `1` if any switch failed or the script couldn't run.
Useful when calling it from another script or a scheduler.

---

## All parameters

| Parameter | Mode | Description |
|---|---|---|
| `-Mac` | single | Switch MAC address, any format. |
| `-Password` | single | New root password. Leave out to be prompted. |
| `-File` | batch | CSV of `mac,password` lines. |
| `-WhatIf` | both | Look up and report only; write nothing. |
| `-IniPath` | both | Settings file. Default: `mist_switch_root_password.ini` next to the script. |
| `-OrgId` | both | Use this org instead of `[mist] org_id`. |
| `-Cloud` | both | Use this cloud instead of `[mist] cloud`. |

`-Mac` and `-File` can't be used together. More examples:

```powershell
# Another customer's settings file
./Set-MistSwitchRootPassword.ps1 -IniPath .\Customer_A.ini -File .\customer_a_switches.csv

# Same token, different org and cloud
./Set-MistSwitchRootPassword.ps1 -Cloud eu -OrgId 11111111-2222-3333-4444-555555555555 -Mac 010203040506

# Built-in help
Get-Help ./Set-MistSwitchRootPassword.ps1 -Full
```

---

## How it works

For each switch:

1. **Find the site** – `GET /orgs/{org_id}/inventory?mac={mac}&vc=true`. The inventory
   lists every claimed switch, whether it's online or not, with its `site_id`.
2. **Read the switch config** –
   `GET /sites/{site_id}/devices/00000000-0000-0000-1000-{mac}`
   (a Mist switch's device ID is always that fixed prefix followed by its MAC).
3. **Merge** – take the existing `switch_mgmt` block (or an empty one if there isn't one)
   and set `root_password`. Nothing else in the block is touched.
4. **Write** – `PUT` the same URL with a body containing only `{ "switch_mgmt": { … } }`.
   Mist only replaces the top-level fields you send, so the rest of the switch config
   is unaffected.
5. **Verify** – read the switch again and check the stored password matches.

Before any switch is processed, one call to `GET /orgs/{org_id}` checks the token, cloud and
network path, so a wrong token or proxy problem fails once with a clear message instead of
once per switch.

### Override precedence

A root password can be set at org level (switch template), site level (site settings) or
on the switch itself. This script sets the **switch-level** value, which wins over the
others. Removing the switch-level value later makes the switch fall back to the site or
template password.

---

## Virtual Chassis

A Virtual Chassis is configured in Mist as one device using the VC's **virtual MAC**, not
the MACs of its member switches. The script handles this for you: if you give the MAC of a
member switch, it looks up which VC the member belongs to and sets the password on the VC.
The result note shows this, e.g. `VC member - set on VC 01:02:03:04:05:09`.

You can also give the VC's virtual MAC directly. Don't list a VC member **and** its VC (or
two members of the same VC) in one CSV with different passwords – the last one processed
wins.

---

## Password rules

The script checks each password before sending it:

- 6 to 128 characters
- printable ASCII only (letters, digits, spaces, symbols – no accented letters or emoji)
- no spaces at the very start or end

Junos may have stricter rules of its own (for example a minimum number of character
classes). If the switch rejects the password, the Mist config push to that switch fails –
check the switch's events in the Mist portal.

---

## Proxy / Zscaler

Optional `[network]` section in the ini:

```ini
[network]
verify_ssl  = true
proxy       = http://proxy.company.com:8080
proxy_use_default_credentials = false
```

| Key | Meaning |
|---|---|
| `verify_ssl` | `false` turns off TLS certificate checks. Last resort for troubleshooting only. |
| `proxy` | Explicit proxy URL. Leave empty to use the system default. |
| `proxy_use_default_credentials` | `true` sends your Windows logon credentials to the proxy. |

PowerShell trusts the operating-system certificate store, so a Zscaler (or other TLS
inspection) root CA already installed in Windows or the macOS Keychain works without
any extra settings.

---

## Troubleshooting

| Message | Cause / fix |
|---|---|
| `Settings file not found` | Copy the `.ini.example` to `mist_switch_root_password.ini` next to the script, or use `-IniPath`. |
| `api_token is missing or empty` | Fill in `api_token` in the ini. |
| `HTTP 401 Unauthorized` | Token is wrong, revoked, or from a different cloud than `cloud =`. |
| `HTTP 403 Forbidden` | Token can't see this org, or is read-only. Needs write access. |
| `not found in the org inventory` | Wrong MAC, or the switch is in a different org. |
| `not assigned to a site` | The switch is claimed but not assigned to a site yet – assign it in the portal. |
| `is a 'ap', not a switch` | The MAC belongs to an AP or gateway. |
| `Could not reach … certificate problem` | TLS inspection (Zscaler etc.). Install its root CA in the OS store, see [Proxy / Zscaler](#proxy--zscaler). |
| `These MACs appear more than once` | Remove the duplicate lines from the CSV. |
| `PUT returned OK but read-back shows a different root_password` | Very unusual – check the switch in the portal. |

---

## Security notes

- The real `.ini` (API token) and `.csv` files (passwords) are git-ignored. Only the
  `.example` files belong in the repo.
- A password typed on the command line is saved in your shell history. Use the prompt
  (leave out `-Password`) or a CSV file you delete afterwards.
- Mist stores the root password in the switch config, so anyone with read access to the
  org's API or portal can see it.
- The results table never shows passwords.
