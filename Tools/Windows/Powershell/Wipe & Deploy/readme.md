# WipeDeploy — Automated System Sanitization & Redeployment Toolkit

## Overview
WipeDeploy is a complete end-to-end solution for secure IT asset disposition and Windows redeployment. It automates the NIST SP 800-88 Rev.1-compliant sanitization of storage devices (HDD, SSD, NVMe) and launches unattended Windows installations, providing a fully traceable audit trail for every machine processed.

This toolkit is designed for technicians working in electronics recycling, IT asset disposition, or large-scale Windows deployments.

---

## Project Components

### 1. `BUILD_USB.BAT`
- Prepares a USB deployment drive
- Copies Windows installation files and required sanitization tools
- Creates standardized folder structure for logs, tools, and temporary work files

### 2. `STARTNET.CMD`
- Executes automatically in WinPE
- Initializes networking and locates the deployment USB
- Launches the deployment script without manual intervention

### 3. `WIPE_AND_DEPLOY.BAT`
- Core deployment engine
- Prompts technician for sanitization level (Clear or Purge) and ID
- Detects drive type (HDD/SSD/NVMe) and executes appropriate NIST-compliant sanitization
- Extracts OEM product key from UEFI for unattended Windows installation
- Partitions the drive, generates `autounattend.xml`, and launches setup
- Logs every step with detailed machine-specific audit records

### 4. `VIEW_LOGS.BAT`
- Audit and verification utility
- Aggregates all sanitization logs
- Summarizes pass/fail results
- Allows detailed review of individual machine logs
- Provides operational visibility and compliance assurance

---

## Key Features
- **NIST SP 800-88 Rev.1 compliant sanitization**
- Supports HDD, SATA SSD, and NVMe drives
- Fully unattended Windows installation
- Technician-friendly, interactive CLI interface
- Audit trail and verification for every machine
- Modular, script-based design for flexibility

---

## Skills Demonstrated
- Batch scripting and Windows CLI automation
- Secure data sanitization workflows
- Windows deployment automation and `autounattend.xml` generation
- Log aggregation, audit, and compliance verification
- Operational tooling for IT asset disposition

---

## Usage
1. Run `BUILD_USB.BAT` on a technician workstation to prepare the USB
2. Boot target machine into WinPE; `STARTNET.CMD` launches deployment automatically
3. Technician provides sanitization level and ID
4. `WIPE_AND_DEPLOY.BAT` sanitizes, partitions, and installs Windows
5. Use `VIEW_LOGS.BAT` to review outcomes and generate audit reports
