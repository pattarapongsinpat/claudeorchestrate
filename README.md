# Claude Orchestrate

Global autonomous implementation workflow for Claude Code. Claude orchestrates intent, review, and verification. DeepSeek generates plans, tests, and implementation steps.

## Requirements

- Claude Code
- Git and Bash
- `jq`, `curl`, and `rg`
- Python and `pytest`
- A DeepSeek API key

## Windows installation

```powershell
git clone https://github.com/pattarapongsinpat/claudeochestrate.git "$HOME\.claudeochestrate"
Set-Location "$HOME\.claudeochestrate"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## macOS or Linux installation

```bash
git clone https://github.com/pattarapongsinpat/claudeochestrate.git ~/.claudeochestrate
cd ~/.claudeochestrate
bash install.sh
```

Set the key in `~/.claudeochestrate/.env`:

```text
DEEPSEEK_API_KEY=your-key
```

Restart Claude Code. Ask for a code change normally. Claude can invoke the build skill automatically. Use `/build <request>` to invoke it explicitly.

## Update

```bash
cd ~/.claudeochestrate
git pull
```

Rerun the installer after command or skill changes.
