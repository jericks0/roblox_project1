# Schema validation tests

The tests use Roblox's built-in `TestService` and do not require TestEZ or DataStore access.

1. Run `rojo serve` from the project root and connect the Aetheria project in Roblox Studio.
2. Open **View → Command Bar** in Studio.
3. Run:

   ```lua
   require(game:GetService("TestService").Tests.SchemaValidationTests)()
   ```

4. Read the Output window. The test module prints one `PASS` line per case and a final count. Any failed assertion stops the run with a descriptive error.

The test module is mapped under `TestService` by `default.project.json`; the production bootstrap is not involved. The tests validate templates and pure record validation only.
