# Security policy

## Supported versions

Before 1.0, newest minor line receives all fixes. Immediately preceding minor
line receives high and critical security backports for 90 days after its
successor is released. Older lines are unsupported. Users must run latest patch
of a supported line.

| Version | Support |
| --- | --- |
| 0.1.x | Supported once 0.1.0 is released |
| Unreleased snapshots | No security support |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
[private vulnerability reporting](https://github.com/ferrreo/ploof/security/advisories/new).
Include affected revision or version, deployment topology, impact, a minimal
reproducer, and any known mitigation. Do not include real credentials or user
data.

Maintainers will acknowledge a complete report within three business days,
coordinate validation and disclosure, and credit the reporter unless anonymity
is requested. No fixed remediation deadline is promised before scope and
severity are known.

Disclosure follows a tested fix. Advisory states affected versions, impact,
mitigation, and upgrade path. When publication is safe, embargoed reproducer is
minimized into public security-corpus regression. Emergency releases still pass
every mandatory gate relevant to the correction; a skipped gate is not a pass.

Ploof terminates TLS at an external reverse proxy in version one. Reports about
Caddy, nginx, Zig, or Linux should also be sent to their maintainers when defect
is not in Ploof. Never send private Ploof reports to a public upstream tracker
before coordinated disclosure.
