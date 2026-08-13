# Target x86_64 first

Ploof version one will support x86_64 Linux only. This lets explicit SIMD,
generated assembly inspection, native fuzzing, and performance gates share one
measured architecture while Zig 0.16 does not perform loop autovectorization.
Hot algorithms will retain simple scalar reference implementations for
differential testing, and architecture-specific code will stay private so
AArch64 can be added later without changing the application API.
