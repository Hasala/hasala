# iOS app unit tests: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaTests/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## APNs profile fixtures are synthetic and end in `.mobileprovision.fixture`

The fixtures in `ios/HasalaTests/Fixtures/apns/` are the vectors of spec 06 §11.3. They
are synthetic. Each one has the shape of a real provisioning profile: a PKCS#7 envelope
with the property list in the clear. It has no certificates, no devices and no names. It
has only the team id and the bundle id, which are public.

The file names end in `.mobileprovision.fixture`, not in `.mobileprovision`. The
repository ignores `*.mobileprovision` (`.gitignore`), so that nobody commits a real
profile by accident. A fixture with the real extension would not be committed, and the
tests would fail on a clean checkout.

Do not replace a fixture with a real profile, and do not remove the `.gitignore` rule to
make a fixture name shorter. A real profile contains certificates, device identifiers and
names.

Applies to: `ios/HasalaTests/APNsEnvironmentTests.swift` (`APNsEnvironmentTests`),
`ios/HasalaTests/Fixtures/apns/`.

## The app tests use an in-app fake of hasalad, not CoreTestSupport

The `HasalaTests` target does not link CoreTestSupport, thus it cannot use the
`FakeServer` of HasalaCore. When the target links CoreTestSupport, Xcode builds the
products of HasalaCore as dynamic libraries. That build loses the `HasalaICU` system
library, and the app does not link.

Thus the app tests have their own fake, `MiniHasalad`. It is a small fake of the password
account routes of `02` §7, in memory. It keeps what the client sends and answers in the
JSON shapes of `02`. It runs the shipped view models over `LiveAccountService` and the
real CoreSync ceremonies (spec 04 §15.1).

`MiniHasalad` checks no signatures. The scenarios that need a signature check (writer
revocation, sync) stay in the suites of HasalaCore, which use `FakeServer`. Do not move
such a scenario into `HasalaTests`: it would pass there without a check. Do not add
CoreTestSupport to the `HasalaTests` target in `ios/project.yml` to get `FakeServer`.

Applies to: `ios/HasalaTests/LiveAccountFlowTests.swift` (`MiniHasalad`),
`ios/HasalaTests/LiveAccountServiceTests.swift`, `ios/project.yml` (target `HasalaTests`).
