# Claude Orchestrate

Global autonomous implementation workflow for Claude Code. Claude orchestrates intent, review, and verification. DeepSeek generates plans, tests, and implementation steps.

## Requirements

- Claude Code
- Git and Bash
- `jq`, `curl`, and `rg`
- A DeepSeek API key

Install the native toolchain used by your projects:

| Projects | Required tools |
|---|---|
| Python | Python and pytest |
| JavaScript or TypeScript | Node.js and the project's package manager |
| Go | Go |
| Rust | Rust and Cargo |
| Java | A JDK and Maven or Gradle |
| C# | .NET SDK |
| C or C++ | CMake, Meson, or Make plus a compiler |

## Windows installation

```powershell
git clone https://github.com/pattarapongsinpat/claudeorchestrate.git "$HOME\.claudeorchestrate"
Set-Location "$HOME\.claudeorchestrate"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## macOS or Linux installation

```bash
git clone https://github.com/pattarapongsinpat/claudeorchestrate.git ~/.claudeorchestrate
cd ~/.claudeorchestrate
bash install.sh
```

Set the key in `~/.claudeorchestrate/.env`:

```text
DEEPSEEK_API_KEY=your-key
```

Restart Claude Code. Ask for a code change normally. Claude handles clearly
localized, low-risk edits directly and routes larger or riskier work through the
build pipeline. Use `/build <request>` to force the full pipeline.

On Windows, the integration launches Git Bash explicitly through
`pipeline/invoke.ps1`. It does not depend on the `bash` command in `PATH`, which
may otherwise launch WSL.

Supported languages are Python, JavaScript, TypeScript, Go, Rust, Java, C#,
C, and C++. C and C++ use the project's existing native test suite. C# uses
generated tests when a test project exists and compile-only verification otherwise.

## Repository configuration

Commit `.pipeline-toolchain.json` when automatic detection does not represent the
real suite. It may override `test_command`, `load_command`, `collect_command`,
`setup_commands`, `selector_mode`, `generated_tests`, `generated_test_file`, and
`framework`. For compiled red-to-green tests, make `load_command` build the
pre-existing suite while omitting projects that intentionally reference the new API.

The model safety scanner rejects writable files containing credential-shaped text.
For a reviewed false positive, copy the exact hash and path printed by `ctx.sh` into
the committed `.pipeline-model-allow` file. The approval stops matching if either
the path or line content changes. `.pipeline-model-exclude` remains the option for
files that must never be sent to a model.

## Pipeline tests

On Windows, run the installed-toolchain smoke suite with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 smoke_adapters
```

Run against a project without changing the caller's working directory:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claudeorchestrate\pipeline\invoke.ps1" run -Repo "C:\path\to\project"
```

Test Maven without installing Java system-wide with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_java.ps1
```

Run real DeepSeek implementation loops for compiled languages:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_java.ps1 -E2E
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled csharp
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled c
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled cpp
```

Test the Make adapter without installation or UAC with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_make.ps1
```

The Java runner verifies downloaded JDK and Maven checksums and removes its
temporary toolchain after the suite finishes.

Run every supported Windows adapter with temporary checksum-verified toolchains:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_all_toolchains.ps1
```

## Update

```bash
cd ~/.claudeorchestrate
git pull
```

Rerun the installer after command or skill changes.
