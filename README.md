# nonmem-compare

Run the [nlmixr2test](https://github.com/nlmixr2/nlmixr2test) NONMEM cross-version
comparison across every supported NONMEM version × Ubuntu LTS × gfortran combination
using Docker containers.

This repository is designed to run on any Ubuntu 24.04 LTS machine, including a
**Raspberry Pi 4/5** (arm64). On arm64, only NONMEM 7.5.1 and 7.6.0 on Ubuntu ≥ 22.04
are supported (20 image variants). On amd64, the full matrix of 162+ combinations
is available.

## Repository structure

```
nonmem-compare/
├── Makefile                    # Runs all NONMEM jobs in parallel
├── setup_root.sh               # System setup (run as root/sudo once)
├── setup_user.sh               # User setup (run as target user once)
├── setup-docker-pull.sh        # Pull Docker images from ECR
├── setup-docker-build.sh       # Build Docker images from source
├── collect-results.sh          # Package results into a zip file
├── nlmixr2test/                # Submodule: nlmixr2/nlmixr2test (CTL/data files)
└── Pharmacometrics-Docker/     # Submodule: NONMEM Docker image build tooling
```

## Prerequisites

- **Hardware**: Any amd64 or arm64 machine (Raspberry Pi 4/5 recommended for arm64)
- **OS**: Ubuntu 24.04 LTS
- **Disk space**:
  - arm64: ~50 GB for images + ~2 GB for results
  - amd64: ~500 GB for images + ~20 GB for results
- **NONMEM Docker images**: access via ECR (requires AWS credentials) or build from source
  (requires NONMEM installer files from Icon)

## Setup

### Step 1: Set up GitHub access

The repository and its submodules are hosted on GitHub. You need either an SSH
key or a personal access token configured before cloning.

#### Option A: SSH key (recommended)

```bash
# Generate a new SSH key (skip if you already have one)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Print the public key — copy this output
cat ~/.ssh/id_ed25519.pub
```

Add the public key to your GitHub account:
1. Go to **GitHub → Settings → SSH and GPG keys → New SSH key**
2. Paste the key and save

Test the connection:

```bash
ssh -T git@github.com
# Expected: "Hi <username>! You've successfully authenticated..."
```

#### Option B: HTTPS with a personal access token

```bash
# Install the Git credential helper (included with Git on most systems)
git config --global credential.helper store

# On first clone/push, Git will prompt for your username and token.
# Generate a token at: GitHub → Settings → Developer settings →
#   Personal access tokens → Tokens (classic) → New token
# Required scopes: repo (read)
```

### Step 2: Clone with submodules

```bash
# SSH (recommended — requires Step 1 Option A):
git clone --recurse-submodules git@github.com:humanpred/nonmem-compare.git
cd nonmem-compare

# HTTPS (requires Step 1 Option B):
git clone --recurse-submodules https://github.com/humanpred/nonmem-compare.git
cd nonmem-compare
```

### Step 3: Root system setup

Run once as root/sudo. This installs Docker CE and adds your user to the `docker` group.
Include `--with-awscli` if you plan to pull images from ECR.

```bash
# Basic (no AWS CLI):
sudo ./setup_root.sh --user $USER

# With AWS CLI (for ECR image pull):
sudo ./setup_root.sh --user $USER --with-awscli
```

**After this step, run `newgrp docker`** (or log out and back in) for the docker group
membership to take effect.

### Step 4: User setup

Run once as the user who will run make:

```bash
./setup_user.sh
```

This initializes the git submodules and checks AWS CLI configuration if applicable.

### Step 5: Get Docker images

Choose **one** of the following options.

#### Option A: Pull from ECR

Images are stored in a private AWS ECR repository. Access requires AWS credentials
with read access to the registry. Contact Human Predictions LLC for access.

> **Note:** NONMEM Docker images cannot be publicly distributed due to the NONMEM
> license agreement.

```bash
# Configure AWS credentials first (if not already done):
aws configure

# Pull all known-working images for your architecture:
./setup-docker-pull.sh
```

For non-default registry or region:

```bash
./setup-docker-pull.sh --registry <ECR_REGISTRY_URL> --region us-east-1
```

#### Option B: Build from source

Building requires NONMEM installer zip files and a license from Icon. See the
[NONMEM website](https://www.iconplc.com/solutions/technologies/nonmem/) for
licensing information.

**1. Set up `nonmem_passwords.conf`:**

The NONMEM installer zip files are password-protected. The passwords are provided
with your NONMEM license.

```bash
cp Pharmacometrics-Docker/nonmem_passwords.conf.example \
   Pharmacometrics-Docker/nonmem_passwords.conf
$EDITOR Pharmacometrics-Docker/nonmem_passwords.conf
```

The file format is:

```ini
# Directory containing NONMEM zip files and nonmem.lic
NONMEM_ZIP_DIR="/path/to/your/nonmem/files"

# Passwords for each NONMEM version (from your NONMEM license)
PASS_720="..."
PASS_730="..."
PASS_74x="..."
PASS_75x="..."
PASS_760="..."
```

> **Security:** `nonmem_passwords.conf` is gitignored. Never commit it or any file
> containing NONMEM passwords or license keys to version control.

**2. Place NONMEM files:**

Copy your NONMEM installer zips and license file into the directory specified by
`NONMEM_ZIP_DIR` in your `nonmem_passwords.conf`. For arm64 you only need 7.5.1
and 7.6.0:

```
$NONMEM_ZIP_DIR/
├── nonmem.lic       # NONMEM license file
├── NONMEM751.zip    # NONMEM 7.5.1 installer
└── NONMEM760.zip    # NONMEM 7.6.0 installer
```

**3. Build images:**

```bash
# Build for host architecture (auto-detected):
./setup-docker-build.sh --jobs 4
```

On an amd64 host, add `--arm64` to also build arm64 images (requires docker buildx
with QEMU; see `Pharmacometrics-Docker/build_matrix.sh` for setup instructions).

### Step 6: Run the comparison

From the repository root:

```bash
# Use all available cores (recommended):
make -j$(nproc)

# Or specify explicitly (e.g., 4 cores on a Raspberry Pi):
make -j4
```

Make automatically discovers all locally available Docker images and all CTL files
in the `nlmixr2test` submodule. Each NONMEM run gets its own isolated directory
to prevent parallel job conflicts.

Expected output per tag (e.g., `7.6.0-ubuntu24.04-gfortran12-arm64/`):

```
7.6.0-ubuntu24.04-gfortran12-arm64/
├── ode/
│   ├── runODE001.lst          # NONMEM output (complete runs only)
│   ├── runODE001.nmfe.log     # nmfe stdout+stderr
│   ├── ...
│   └── .failures              # created only if any runs failed
└── solved/
    ├── runSolve001.lst
    └── ...
```

To resume after interruption, simply re-run `make -j$(nproc)` — Make skips
already-completed `.lst` files.

### Step 7: Collect results

```bash
./collect-results.sh
```

This creates a timestamped zip file (e.g., `nonmem-results-20260413-120000.zip`)
containing all `.lst`, `.ext`, `.cov`, `.cor`, `.coi`, `.phi`, `.xml`, `.grd`,
`.shk`, `.shm`, `.clt`, `.cpu`, `.nmfe.log`, and `.failures` files, plus
`system_details.txt`.

## Known issues

### gfortran 13/14 + ADVAN13 SIGSEGV (NONMEM 7.5.1 / 7.6.0)

NONMEM 7.5.1 and 7.6.0 compiled with gfortran 13 or 14 crash with a segmentation
fault (SIGSEGV) on specific oral 2-compartment ODE models that use `ADVAN13`
(`$SUBROUTINE ADVAN13`). The crash occurs reproducibly mid-estimation after 15–25
iterations; all analytically-solved models and most ODE models run successfully.

Affected CTL files:
- `runODE063` — 2-CPT oral, all doses
- `runODE068` — 2-CPT oral, Michaelis-Menten, single dose
- `runODE069` — 2-CPT oral, Michaelis-Menten, multiple dose
- `runODE070` — 2-CPT oral, Michaelis-Menten, all doses

These are included in `nlmixr2test/nonmem/icon-bug-report/` and have been filed
with Icon. The gfortran 13/14 Docker images are still pulled/built (they correctly
run all other models) but their `.failures` files will contain these four entries.

### arm64 limited to NONMEM 7.5.1 and 7.6.0

NONMEM versions prior to 7.5.1 use x86-specific installer scripts and do not
support arm64 compilation. Only NONMEM 7.5.1 and 7.6.0 on Ubuntu 22.04/24.04
are available for arm64.
