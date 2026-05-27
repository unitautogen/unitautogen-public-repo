# Security Policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in **UnitAutogen**, please report it privately — *do not* open a public GitHub Issue.

Email: **security@unitautogen.com**

In your report, please include:

- A description of the vulnerability and the impact you believe it has.
- The affected version of UnitAutogen (see the [`VERSION`](VERSION) file).
- Steps to reproduce, including any specific SQL Server version, tSQLt version, and a minimal example procedure if relevant.
- Any suggested mitigation or patch, if you have one.

## What to expect

- We will acknowledge receipt of your report within **5 business days**.
- We will investigate and respond with an initial assessment within **14 days**.
- We will keep you informed as we work on a fix.
- Once the fix is released, we will credit you in the release notes (unless you prefer to remain anonymous).

## Supported versions

Because UnitAutogen is in Beta, only the **latest release** receives security updates. Once the v1.0 line is stable, we will publish a longer support policy here.

## Scope

In scope:

- The UnitAutogen installer and module SQL code in this repository.
- The Patch scripts in `scripts/`.

Out of scope (please report to the upstream project):

- Vulnerabilities in tSQLt itself.
- Vulnerabilities in SQL Server, Microsoft AdventureWorks / Northwind / WideWorldImporters sample databases, or any other third-party software UnitAutogen depends on or interacts with.

Thank you for helping keep UnitAutogen and its users secure.
