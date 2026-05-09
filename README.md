# Da Serva

**A single-file Minecraft Fabric server manager for Windows.**

No installer. No dependencies. No setup. Just one `.bat` file.

---

## What it does

Da Serva handles everything needed to create and maintain a Minecraft Fabric server:

- Queries Modrinth to find the newest MC version where **all your mods have a Fabric release**
- Downloads the correct Fabric server jar automatically
- Downloads all mods and their dependencies, verifying each file via **SHA1 checksum**
- Detects and installs the correct Java version for the target MC version
- Configures Geyser + Floodgate for **Bedrock Edition support**
- Backs up your world and config before any update, restores them after
- Writes and merges `server.properties` on every server launch so your settings always win
- Remembers your last server and mod configuration across sessions

---

## Download

Download **`DaServa.bat`** from [Releases](../../releases) and double-click it. That's it.

> No separate files needed. The entire application is embedded in the `.bat` file.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1+ (pre-installed on all modern Windows)
- Internet connection (for downloading mods and server files)
- Java (will be installed automatically if missing)

---

## Usage

### First run

Double-click `DaServa.bat`. You'll see the main menu:

```
[1] Create a New Server       (Fresh install -- auto-detects best MC version)
[2] Update an Existing Server (Updates server + mods, preserves world)
[3] Manage Mods               (Add/remove mods without touching your world)
[4] Help                      (How to use Da Serva, keybinds, and more)
[5] Exit
```

### Create a New Server

1. Opens the **mod selector** — toggle mods on/off, search Modrinth, add custom mods
2. Da Serva queries every mod's Fabric releases and finds the **newest MC version they all support**
3. Opens the **version selector** — pick from the compatible list
4. Choose an install folder (default: next to `DaServa.bat`)
5. Downloads and installs everything
6. Optionally launch the server immediately

### Update an Existing Server

1. Select your server folder (auto-detected from the script directory)
2. Da Serva **scans your existing mods via SHA1 hash** to pre-populate the mod selector
3. Adjust mods, pick a new version, confirm
4. World + config are **backed up**, old server files wiped, new ones installed, world + config **restored**

### Manage Mods

Add, remove, or swap mods on a running server without touching the world or server jar. Only the `mods/` folder is affected.

---

## Mod Selector

The mod selector is a full interactive TUI:

| Key | Action |
|-----|--------|
| `UP` / `DOWN` | Navigate |
| `PgUp` / `PgDn` | Scroll by page |
| `Home` / `End` | Jump to top / bottom |
| `SPACE` | Toggle mod on/off |
| `A` | Add a mod (search Modrinth, or paste a URL/slug) |
| `D` | Remove a custom mod |
| `E` | Enable all visible mods |
| `N` | Disable all visible mods |
| `/` | Enter search mode (type freely, no keybind conflicts) |
| `ESC` | Exit search mode |
| `F` | Cycle filter: All → Server → Client → Both → Enabled → Disabled |
| `H` | Toggle help panel |
| `B` | Back to main menu |
| `ENTER` | Confirm and continue |

Each mod shows:
- `[Server]` / `[Client]` / `[Both]` — which side needs the mod
- Supported MC version ranges (e.g. `26.1.x  1.21.x  1.20.x`)
- Last updated time (e.g. `3d ago`, `2mo ago`)
- `[caps version]` in yellow — this mod is limiting your maximum server version

The bottom bar shows the **maximum compatible MC version** and which mods are capping it. Disable them to unlock a newer version.

---

## Default Mod List

Da Serva ships with 35 default mods covering performance, quality of life, and Bedrock support:

| Category | Mods |
|----------|------|
| **Bedrock support** | Geyser, Floodgate |
| **Performance** | Lithium, FerriteCore, Krypton, C2ME, ScalableLux, I'm Fast |
| **World generation** | Tectonic, Terralith, Lithostitched, Towns and Towers |
| **Admin tools** | LuckPerms, Invsee++, Vanish, Chunky, Carpet, WorldEdit |
| **Quality of life** | Fabric API, Image2Map, Just Player Heads, Just Mob Heads, Collective |
| **Fixes** | Not Enough Animations, Packet Fixer, Debugify, AttributeFix |
| **Libraries** | Cristel Lib, Prickle, Clumps, Collective |
| **Other** | Distant Horizons, Waystones, Villager Names, WorldEdit Hang Fix |

All mods can be toggled off individually. You can also add any mod from Modrinth via search.

---

## Geyser + Floodgate (Bedrock Support)

Da Serva pre-configures Geyser and Floodgate so Bedrock Edition players can join your Java server.

- Geyser config is written to `config/Geyser-Fabric/config.yml` automatically
- Floodgate generates `key.pem` on first server startup — `start.bat` copies it to the Geyser config folder on **every launch** so you never have to do it manually
- Bedrock clients connect on **UDP port 19132** — make sure this is open in your firewall/router

---

## Java Version Detection

Da Serva automatically determines the correct Java version for your target MC version:

| Minecraft Version | Java Required |
|------------------|---------------|
| 26.x+ | Java 25 |
| 1.20.5 – 1.21.x | Java 21 |
| 1.18 – 1.20.4 | Java 17 |
| 1.17 | Java 16 |
| 1.16 and below | Java 8 |

If the required Java version isn't installed, Da Serva offers to install it via `winget` automatically.

---

## server.properties

Da Serva uses a **merge strategy** — it only sets specific keys and leaves everything else untouched. The merge runs on every server launch via `_startup_helper.ps1`, so your settings always win even if the server rewrites the file.

Keys managed by Da Serva:

```properties
gamemode=creative
difficulty=easy
online-mode=true
server-port=25565
motd=Da Serva
resource-pack=https://...
enforce-secure-profile=false
```

Everything else (seed, whitelist, ops, view distance, etc.) is yours to configure and will be preserved across updates.

---

## Mod Profiles

After every Create / Update / Manage, Da Serva saves a `mod_profile.json` in the server folder recording every mod's slug and enabled state.

On the next run, if a profile is found, you'll be asked whether to load it — restoring your exact mod configuration in one keypress.

Profiles are portable — copy `mod_profile.json` next to `DaServa.bat` on another machine and it will be offered automatically.

---

## Quiet Mode

Run with `-Quiet` for unattended use:

```bat
DaServa.bat -Quiet
```

In quiet mode, all yes/no confirmations auto-accept with their default answer and all pause prompts are skipped. The interactive mod selector and version selector still require input — quiet mode only skips confirmations.

Useful for scheduled update scripts and CI pipelines.

---

## How the single-file trick works

`DaServa.bat` is a valid batch file that extracts and runs embedded PowerShell code from itself at launch:

1. The batch section runs `powershell -Command` to read the `.bat` file, find the `#---PSSTART---` marker, extract everything after it to a temp `.ps1` file, and run it
2. `exit /b` ensures batch never executes the PowerShell code directly
3. The temp file is deleted after the session ends

This means the entire ~2500 line PowerShell application lives inside a single double-clickable `.bat` file with no extraction step needed by the user.

---

## File structure after setup

```
DaServa.bat                          <- the manager (keep this)
daserva_config.json                  <- remembers your last server path

Minecraft 1.21.11 Fabric Server/
  start.bat                          <- run this to start the server
  _startup_helper.ps1                <- merges server.properties on launch
  mod_profile.json                   <- your saved mod configuration
  fabric-server-mc.1.21.11-...jar    <- the server jar
  eula.txt
  server.properties
  mods/
    fabric-api-0.141.3+1.21.11.jar
    geyser-fabric-2.9.6-b1133.jar
    ... (all your mods + dependencies)
  config/
    Geyser-Fabric/
      config.yml
      key.pem                        <- auto-copied from floodgate on launch
    floodgate/
      key.pem
  world/
    ...
```

---

## Credits

- [FabricMC](https://fabricmc.net/) — Fabric mod loader
- [Modrinth](https://modrinth.com/) — mod hosting and API
- [GeyserMC](https://geysermc.org/) — Bedrock bridge
- [Floodgate](https://github.com/GeyserMC/Floodgate) — Bedrock auth
- [Eclipse Temurin](https://adoptium.net/) — Java distribution

---

## License

MIT
