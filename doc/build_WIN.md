# Build guide for Windows

## Choose one independent build option

Choose exactly one option below. Do not mix commands, prerequisites, or paths
between the two options.

## Option 1: Native MSVC build

Use this option only from a native **Developer PowerShell** or
**Developer Command Prompt** (MSVC `cl`, `link`, `lib` in `PATH`).

### Prerequisites

- Windows Server 2025
- Git for Windows (`git`)
- Python + Meson (`meson`)
- Ninja (`ninja`)
- pkg-config compatible tool (`pkg-config` or `pkgconf`)
- Visual Studio Build Tools / MSVC (Developer shell)

### Build DPDK (standalone script-managed workspace)

```powershell
.\script\build_dpdk_windows.ps1
```

Script-owned workspace and output paths:

```text
build\windows-dpdk\src
build\windows-dpdk\src\dpdk-${DPDK_VER}\build
build\windows-dpdk\install
```

The script reads `DPDK_VER` and `DPDK_MTL_MINOR_VER` from `versions.env`,
fetches a clean DPDK `v${DPDK_VER}` source tree, applies:

1. `patches/dpdk/${DPDK_VER}/*.patch` (`git am`)
2. `patches/dpdk/${DPDK_VER}/windows/*.patch` (`git apply`)

Then it configures DPDK from the source root with an in-tree build
subdirectory (`build\windows-dpdk\src\dpdk-${DPDK_VER}\build`) using:

- `-Dmax_lcores=256`
- `-Ddefault_library=shared`
- `-Denable_stdatomic=true`
- `-Dtests=false`
- `-Ddisable_apps=test-bbdev,test-cmdline,test-fib,test-flow-perf,test-gpudev,test-pmd,test-regex`

This avoids MSVC link failures in unsupported DPDK test apps
(`usual_getopt*`, `getline`) and installs headers, generated
`rte_config.h`, DPDK libraries/drivers, and `libdpdk.pc`.

Use `-Force` for a clean rerun of script-owned workspace directories.
Without `-Force`, the script keeps the cloned/patched DPDK source tree for
subsequent native MTL builds.

### Build MTL (Native MSVC path)

Run this from the same native Developer shell:

```powershell
.\script\build_mtl_windows.ps1
```

Default script-owned native MTL layout:

```text
build\windows-mtl\lib
build\windows-mtl\app
build\windows-mtl\tests
build\windows-mtl\plugins
build\windows-mtl\rxtxapp
build\windows-mtl\install
```

The script consumes the native DPDK workspace from Option 1 using:

- `build\windows-dpdk\install\lib\pkgconfig\libdpdk.pc` (for Meson dependency discovery)
- `build\windows-dpdk\src\dpdk-${DPDK_VER}` (for `-Ddpdk_root_dir=...`)

Supported script parameters:

- `-WorkspaceRoot <path>` (default: `build\windows-mtl`)
- `-DpdkInstallPrefix <path>` (default: `build\windows-dpdk\install`)
- `-DpdkSourceDir <path>` (default: `build\windows-dpdk\src\dpdk-${DPDK_VER}`)
- `-MtlInstallPrefix <path>` (default: `build\windows-mtl\install`)
- `-BuildType release|debug|debugoptimized|plain` (default: `release`)
- `-ValidateOnly` (prerequisite/layout checks only)
- `-Force` (clean script-owned native MTL build/install directories before rebuild)

Projects built in dependency order:

1. top-level `mtl` library
1. `app`
1. `tests` (build only; this script does not run tests)
1. `plugins`
1. `tests/tools/RxTxApp`

Intentionally skipped on Windows:

- `ld_preload`
- `manager`

Examples:

```powershell
.\script\build_mtl_windows.ps1 -ValidateOnly
```

```powershell
.\script\build_mtl_windows.ps1 -BuildType debug -Force
```

## Option 2: MSYS2/UCRT64 build

Use this option only from the **MSYS2 UCRT64** shell.

### Prerequisites

- Windows Server 2025
- MSYS2 (download from <https://www.msys2.org/>)
- npcap (download from <https://npcap.com/#download>)

### Prepare the MSYS2/UCRT64 environment

1. Run MSYS2 UCRT64.

1. Install tools.

    ```bash
    pacman -S git pactoys unzip
    ```

    ```bash
    pacboy -S dlfcn:p gcc:p gtest:p json-c:p libpcap:p meson:p mman-win32:p
    ```

1. Install npcap SDK.

    ```bash
    wget https://npcap.com/dist/npcap-sdk-1.16.zip
    ```

    ```bash
    unzip -d npcap-sdk-1.16 ./npcap-sdk-1.16.zip
    ```

    ```bash
    cp -r ./npcap-sdk-1.16/lib/x64/. "${MSYSTEM_PREFIX}/lib"
    ```

### Build DPDK (MSYS2 path: `<repo>/dpdk`)

1. Clone the MTL repository

    ```bash
    git clone https://github.com/OpenVisualCloud/Media-Transport-Library.git
    ```

    ```bash
    cd ./Media-Transport-Library
    ```

    ```bash
    MTL_PATH="$PWD"
    ```

1. Clone the DPDK repository

    > **Note:** The DPDK repository should be located directly in the MTL repository root:
    > `<repo>/dpdk`.

    `versions.env` in the MTL repository holds the DPDK version to use. Read the file to set `DPDK_VER`.

    ```bash
    . "$MTL_PATH"/versions.env
    ```

    ```bash
    git clone -b "v${DPDK_VER}" https://github.com/DPDK/dpdk.git
    ```

1. Convert the patch symlinks to files

    Run this step for the DPDK versions 22.03 to 23.11. For every other version, go to the
    next step.

    > **Note:** Some patch files in these versions point to a patch of an older DPDK version.
    > Git can write such a file as a text file that holds the target path. It does this when
    > the checkout has `core.symlinks=false`. A file system that cannot hold symlinks makes
    > Git set this value at clone time. This is frequent on Windows. Some of these files are
    > text in the repository itself. `git am` and `git apply` reject a text file.

    The command replaces each text file with the content of its target. A symlink can point
    to a second symlink. The longest chain in the repository is two hops. The command makes
    three passes, one more than the chain needs. It rewrites only a file whose first line
    starts with `../` and ends with `.patch`, so it is safe to run twice.

    ```bash
    for _ in 1 2 3; do
        for f in "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/*.patch \
                 "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/windows/*.patch; do
            [ -f "$f" ] || continue
            target=$(head -n 1 "$f")
            case "$target" in ../*.patch) cp "$(dirname "$f")/$target" "$f" ;; esac
        done
    done

    for f in "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/*.patch \
             "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/windows/*.patch; do
        [ -f "$f" ] || continue
        case "$(head -n 1 "$f")" in ../*.patch) echo "not converted: $f" ;; esac
    done
    ```

    The command then checks each file again. A line in the output means the conversion is not
    complete. Report such a file in a GitHub issue.

    > **Note:** The three passes are enough only while every chain stays inside one directory
    > depth. A chain such as `23.11/windows/A.patch -> ../../23.07/A.patch -> ../23.03/A.patch`
    > makes the second pass compute the path `23.11/windows/../23.03/A.patch`. This path does
    > not exist, so `cp` writes an error and the text file stays. Nothing in the repository
    > enforces the depth rule.

    Do not commit the result. A commit of the converted tree replaces each symlink with a
    large file. With `core.symlinks=false`, Git keeps the symlink mode and writes the patch
    body as the link target. Such an entry is not valid. No tool in this repository and no CI
    job finds either result.

    To remove the changes, use this command. It restores from `HEAD`, not from the index, so
    it also works after `git add`. It reverts the whole version directory:

    ```bash
    git -C "$MTL_PATH" restore --source=HEAD --staged --worktree patches/dpdk/"${DPDK_VER}"
    ```

1. Apply the MTL patches for DPDK

    ```bash
    cd "${MTL_PATH}/dpdk"
    ```

    ```bash
    git am "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/*.patch
    ```

    ```bash
    git apply "$MTL_PATH"/patches/dpdk/"${DPDK_VER}"/windows/*.patch
    ```

1. Build DPDK

    The DPDK build directory for this flow is `<repo>/dpdk/build`.

    ```bash
    meson setup -Dmax_lcores=256 build
    ```

    ```bash
    meson compile -C build
    ```

    Create a copy of the `sched.h` file

    > **Note:** DPDK installation overwrites the `sched.h` file and cause MTL build problems

    ```bash
    cp "${MSYSTEM_PREFIX}/include/sched.h" "${MTL_PATH}/sched.h.bak"
    ```

    ```bash
    meson install -C build
    ```

    Restore the copy

    ```bash
    cp "${MTL_PATH}/sched.h.bak" "${MSYSTEM_PREFIX}/include/sched.h"
    ```

### Build MTL (MSYS2/UCRT64)

1. Run the build script

    The MSYS2/UCRT64 flow installs DPDK into `${MSYSTEM_PREFIX}` and then builds
    MTL from `<repo>`.

    ```bash
    cd "$MTL_PATH"
    ```

    ```bash
    ./build.sh debugonly
    ```
