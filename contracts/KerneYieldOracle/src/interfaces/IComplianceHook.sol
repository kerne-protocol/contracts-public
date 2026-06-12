// SPDX-License-Identifier: MIT
// Created: 2026-01-09
pragma solidity 0.8.24;

/**
 * @title IComplianceHook
 * @author Kerne Protocol
 * @notice Interface for external compliance/KYC providers.
 */
interface IComplianceHook {
    /**
     * @notice Checks if an address is compliant for a specific vault.
     * @param vault The address of the vault.
     * @param account The address to check.
     * @return bool True if compliant, false otherwise.
     */
    function isCompliant(address vault, address account) external view returns (bool);
}
