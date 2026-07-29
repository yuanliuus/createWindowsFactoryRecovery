# Windows Factory Recovery Manager

`Manage-WindowsFactoryRecovery.ps1` builds, updates, integrates, or completely
removes a local factory-recovery package made from a captured WIM. Installation
separates partition work from boot configuration.

## Interactive one-line launcher

Open Windows PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/yuanliuus/createWindowsFactoryRecovery/main/Invoke-WindowsFactoryRecovery.ps1 | iex
```

The launcher presents a menu for guided creation, a read-only plan,
prepare-only, integration-only, image update, complete removal, or help. Guided
creation runs the plan, asks whether to continue, prepares the recovery
partition and files, and then integrates the verified package. The launcher
downloads the current manager to a temporary file, displays its SHA-256 hash,
requests UAC elevation when needed, and removes the temporary copy afterward.
All confirmations and safety checks in the full manager remain active.

`irm ... | iex` executes code obtained from the network. Review the
[bootstrap source](https://github.com/yuanliuus/createWindowsFactoryRecovery/blob/main/Invoke-WindowsFactoryRecovery.ps1)
before using it, and use a commit-specific raw URL when reproducible,
version-pinned behavior is required.

## Important safety rules

- Run from elevated **Windows PowerShell 5.1**.
- GPT/UEFI basic disks are supported. MBR, dynamic disks, Storage Spaces,
  VHD/VHDX boot, and multi-disk boot layouts are refused.
- Keep tested Windows installation/recovery USB media available.
- Suspend BitLocker before a modifying operation.
- The script never deletes the existing WinRE partition.
- The script never automatically recreates or enlarges an existing factory
  partition. That operation is intentionally offline/manual.
- Removal deletes only a `FACTORY_RECOVERY` partition whose version-2 manifest
  matches the current Windows disk and partition layout.
- No operation reboots the computer.

The default recovery size is 20 GB. Restore always requires typing `RESTORE` and
verifies the recorded GPT disk ID before formatting anything. The recovery
images include their own `findstr.exe` verifier because minimal WinRE images may
not provide that command. The WinRE menu tool also includes `cmd.exe` under its
original filename together with its language resource, rather than renaming the
executable; renamed system tools cannot reliably resolve their MUI messages.

## Options

| Full option | Short | Meaning |
|---|---:|---|
| `--image-path` | `-i` | Captured WIM |
| `--image-index` | `-n` | Lock recovery to one index; default allows all |
| `--recovery-size-gb` | `-s` | New partition size; default 20 |
| `--create` | `-c` | Guided plan, prepare, and integrate workflow |
| `--prepare` | `-p` | Create/populate only |
| `--integrate` | `-g` | BCD and WinRE integration only |
| `--update` | `-u` | Update existing recovery files only |
| `--remove` | `-r` | Completely remove verified factory recovery |
| `--what-if` | `-w` | Stop after the plan |
| `--verbose` | `-v` | Detailed command output |
| `--help` | `-h` | Usage help |

```powershell
.\Manage-WindowsFactoryRecovery.ps1 --help
```

## New installation

### 1. Review the read-only plan

```powershell
.\Manage-WindowsFactoryRecovery.ps1 `
  --image-path 'E:\Windows_Images\factory.wim'
```

The plan reads the WIM, disk layout, BitLocker state, current WinRE registration,
and any existing `FACTORY_RECOVERY` volume. It changes nothing.

If the WIM contains multiple images and `--image-index` is not supplied, the
script records every image index together with its available name, description,
edition, installation type, architecture, version, size, and modified time.
The user chooses from that validated catalog when factory recovery is started,
before typing the destructive `RESTORE` confirmation. A single-image WIM is
selected automatically, but its title and available details are still displayed
before confirmation. After a multi-image choice, the selected image details are
displayed again so the choice can be checked before continuing.

To restrict recovery to one image, specify it explicitly:

```powershell
.\Manage-WindowsFactoryRecovery.ps1 `
  --image-path 'E:\Windows_Images\multi-edition.wim' `
  --image-index 2
```

Recovery never parses localized DISM output to validate the selection. The
build-generated catalog and validator whitelist only indexes that existed in
the copied WIM.

### Guided creation

```powershell
.\Manage-WindowsFactoryRecovery.ps1 --create
```

`--create` first displays the four-stage workflow and asks `y/n`. Only after
approval does it ask for the captured WIM path, recovery partition size, and,
for a multi-image WIM, whether to lock one index or offer every image during
recovery. It then prints the complete read-only machine/WIM plan before using
the existing preparation safety checks and high-impact confirmation.

After preparation, it verifies the copied WIM, rediscovers the new recovery
partition, and continues through the existing checkpointed integration flow.
It still asks whether to add the separate Boot Manager entry. If preparation
fails, integration is never attempted. If integration fails, its BCD and WinRE
rollback remains active while the prepared partition is retained for
inspection.

Parameters can also be supplied in advance for unattended parameter entry
while retaining confirmations:

```powershell
.\Manage-WindowsFactoryRecovery.ps1 `
  --image-path 'E:\Windows_Images\factory.wim' `
  --recovery-size-gb 20 `
  --create
```

### 2. Prepare the partition and files

```powershell
.\Manage-WindowsFactoryRecovery.ps1 `
  --image-path 'E:\Windows_Images\factory.wim' `
  --recovery-size-gb 20 `
  --prepare
```

Type `PREPARE`, then approve PowerShell's high-impact confirmation. This step:

1. Copies the current WinRE image to staging without disabling WinRE.
2. Shrinks the Windows partition.
3. Creates and formats `FACTORY_RECOVERY` at the requested size, reserving
   1 MB for GPT partition alignment.
4. Builds the WinRE tile and separate factory WinPE image.
5. Copies and SHA-256 verifies the captured WIM.
6. Writes a disk/layout manifest and hides the new partition.

The normal WinRE image receives an explicit `Winpeshl.ini` that initializes
WinPE and launches `RecEnv.exe`. Without that shell entry, WinPE falls back to
`Startnet.cmd` and stops at a command prompt after `wpeinit`.

It does **not** call `bcdedit` or modify REAgentC. Existing WinRE is preserved.
Reboot and verify ordinary Windows startup before continuing.

### 3. Integrate only after the successful reboot

```powershell
.\Manage-WindowsFactoryRecovery.ps1 --integrate
```

Type `INTEGRATE`, then approve the high-impact confirmation. Integration:

1. Validates the package manifest against the current disk ID and partitions.
2. Validates the current Windows loader and Boot Manager default.
3. Exports a timestamped BCD checkpoint.
4. Preserves access to the previous WinRE for rollback.
5. Registers the prepared WinRE and supported **Factory Recovery** tile.
6. Asks whether to add the separate Factory Recovery Boot Manager entry.
   Enter `y` to create it or `n` to keep only the WinRE tile.
7. If selected, creates a private BCD ramdisk-options object and Factory
   Recovery loader with a 3-second selection timeout.
8. Confirms the original Windows loader remains the default.

Unlike the previous implementation, it never rewrites the shared
`{ramdiskoptions}` object. If integration fails, it restores the prior WinRE
registration where available and imports the BCD checkpoint.

After integration, reboot and test normal Windows first. Do not perform a real
factory restore on a production machine merely as a test.

For a non-destructive Factory Recovery boot test, boot the **Factory Recovery**
entry, select any listed image index when prompted, verify the displayed title
and details, and then press Enter without typing `RESTORE`. A package locked to
one image selects it automatically but still displays its details. The
cancellation path reboots directly to the normal default Windows loader. If the
disk identity does not match, recovery refuses to format and opens a diagnostic
command prompt.

## Update the captured image

```powershell
.\Manage-WindowsFactoryRecovery.ps1 `
  --image-path 'E:\Windows_Images\new-factory.wim' `
  --update
```

Type `UPDATE`. New files are staged beside the current files, the WIM is
SHA-256 verified, and each file is replaced with a rollback copy. Update mode
does not call `bcdedit`, REAgentC, or partition cmdlets.

If an older package has the expected three recovery images but no version-2
manifest, a successful update adopts it into the new format. This is the safe
migration path for a package left by an earlier script version.

If the new WIM cannot fit, the script asks whether resizing is desired. Typing
`RESIZE` records the intent but stops with instructions to use tested offline
media; online delete-and-recreate resizing is deliberately disabled after the
boot incident. No current recovery file is removed.

Side-by-side update requires enough free space for the new WIM plus 1 GB. This
preserves the old image until the new one has been copied and verified.

## Remove factory recovery

First review the removal plan. No image path is required:

```powershell
.\Manage-WindowsFactoryRecovery.ps1 --remove --what-if
```

To perform the removal:

```powershell
.\Manage-WindowsFactoryRecovery.ps1 --remove
```

The script validates the factory partition and manifest before displaying the
critical prompt. Type `REMOVE-FACTORY`, then approve PowerShell's high-impact
confirmation. It then:

1. Exports a timestamped BCD checkpoint.
2. Builds a clean standard WinRE image with the factory launcher removed.
3. Disables WinRE only when it is registered on the factory partition.
4. Removes the recorded and matching Factory Recovery loader/private ramdisk
   objects, then verifies none remain.
5. Deletes only the verified `FACTORY_RECOVERY` partition.
6. Registers and verifies standard WinRE when relocation is required.
7. Extends the Windows partition only when the released space is directly
   adjacent to it.

If the released space is not adjacent to Windows, it remains unallocated for
manual storage management. The older independent WinRE partition is not
deleted. No reboot is performed.

Removal is intentionally not an ordinary `y`/`n` action. Once the partition has
been deleted, the old BCD checkpoint must not be imported automatically because
it refers to files that no longer exist. The script reports that distinction if
a later step fails.

## Existing WinRE partition

The script reports the current WinRE configuration but never removes its
partition automatically. Retire an old WinRE partition only after:

- normal Windows boot has been tested;
- `reagentc /info` points to `FACTORY_RECOVERY`;
- ordinary WinRE has booted successfully;
- Factory Recovery has booted to its confirmation screen without typing
  `RESTORE`; and
- a full disk backup exists.

Partition cleanup is intentionally outside this script.

## Verification

```powershell
reagentc /info
bcdedit /enum
Get-Disk
Get-Partition
```

Verify Windows RE is enabled, Windows remains the default loader, Factory
Recovery is last in the menu, and the factory partition has no drive letter.

## Mock and static test

```powershell
.\tests\Mock-Test.ps1
```

The test parses the production script, checks critical ordering and safety
invariants, and runs help/plan/WhatIf paths with every mutating command replaced
by a fail-fast guard. It does not change disks, BCD, WinRE, or partitions.

`tests\Verify-RecoveryVerifier.ps1` mounts both installed recovery WIMs
read-only and confirms that the bundled verifier exists, is called by the
restore script, and can match the recorded GPT disk ID.

Ordinary choices accept `y`/`yes` and `n`/`no`. Critical operations deliberately
require their full confirmation words: `PREPARE`, `UPDATE`, `RESIZE`,
`INTEGRATE`, `REMOVE-FACTORY`, and `RESTORE`.

## Development and live test helpers

The `tests` directory is intentionally retained for further development:

- `Mock-Test.ps1` performs non-mutating parser, static, plan, and mock checks.
- `Run-LiveReadOnlyTest.ps1 -ImagePath <capture.wim>` checks an installed
  configuration without changing it.
- `Run-LiveUpdate.ps1 -ImagePath <capture.wim>` exercises the file-only update.
- `Run-LiveIntegrate.ps1` exercises checkpointed WinRE/BCD integration.
- `Run-LiveRemoveCancellationTest.ps1` validates the installed package and real
  removal preflight, deliberately cancels at the critical confirmation, and
  proves that partitions, BCD, and WinRE remain unchanged.
- `Verify-PostIntegrationState.ps1` checks disk identity, hidden partition
  state, manifest index, WinRE registration, private BCD objects, and the
  normal Windows default loader.
- `Repair-InstalledWinREShell.ps1` is a checkpointed repair helper for an
  installed WinRE image that falls back to `wpeinit` and a command prompt
  because its standard `RecEnv.exe` shell entry is missing.
- Boot-test runners schedule one-time normal, FactoryRE, and WinRE menu tests.
- `Verify-RecoveryVerifier.ps1` mounts installed WIMs read-only and tests their
  launcher and disk-identity verifier.

Generated transcripts and machine-specific results belong under `artifacts`;
they are not required to deploy the recovery manager.
