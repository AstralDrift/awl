# Configuration

Settings live in `settings.ini`. In code, read them from the `settings` dict in
`app.config`: `settings["db_url"]`, `settings.get("timeout", 30)`. Values are strings.
