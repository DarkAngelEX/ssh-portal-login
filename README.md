# ssh-portal-login

Open captive portals through an SSH SOCKS5 tunnel with an isolated browser profile.

## Requirements

- OpenSSH client available as `ssh`
- Microsoft Edge, Firefox, or Google Chrome / Chromium
- Python 3.10+ only if you use `ssh_portal_login.py`

## Usage

```bash
# macOS / Linux / Windows with Python
python ssh_portal_login.py TARGET
python ssh_portal_login.py user@a.b.c.d
```

```powershell
# Windows PowerShell, no Python required
.\ssh_portal_login.ps1 TARGET
.\ssh_portal_login.ps1 user@a.b.c.d
```

```bat
:: Windows cmd.exe, no Python required
ssh_portal_login.bat TARGET
ssh_portal_login.bat user@a.b.c.d
```

If PowerShell script execution is blocked:

```powershell
# Windows PowerShell
powershell -ExecutionPolicy Bypass -File .\ssh_portal_login.ps1 user@a.b.c.d
```

Optional Python arguments:

```bash
# Any shell with Python
python ssh_portal_login.py user@a.b.c.d --port 1081
python ssh_portal_login.py user@a.b.c.d --url https://10.248.98.2
```

To change the default portal URL for any script, edit `https://10.248.98.2` near the top of the file.

## How It Works

The tool starts SSH dynamic port forwarding:

```bash
ssh -N -D 127.0.0.1:1080 user@a.b.c.d
```

Then it launches a temporary browser profile using:

```text
SOCKS5 127.0.0.1:1080
```

The system proxy is not changed.

When login is complete, close the browser or press Enter / any key in the script window. The tool stops SSH and removes the temporary browser profile.

## Browser Order

The Python script uses:

```python
BROWSER_SEARCH_ORDER = ["chrome", "edge", "firefox"]
```

The Windows scripts search Chrome, Edge, then Firefox.

## License

MIT
