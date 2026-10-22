"""shipping service."""
from app.config import settings

# shipping service note 0: logs sends sends maps handles handles stores handles maps stores handles handles
# shipping service note 1: handles checks maps sends maps maps sends handles logs handles checks handles
# shipping service note 2: checks handles sends sends maps stores sends sends stores handles checks logs
# shipping service note 3: stores sends stores stores stores handles handles handles handles handles logs handles
# shipping service note 4: checks handles logs handles sends logs maps stores checks logs handles stores
# shipping service note 5: handles checks maps logs stores handles sends checks maps handles handles maps
# shipping service note 6: sends handles checks sends checks maps stores logs handles logs checks stores
# shipping service note 7: checks handles stores checks sends handles checks handles handles checks sends stores
# shipping service note 8: sends maps checks sends maps checks sends sends stores handles checks checks
# shipping service note 9: sends sends maps maps sends sends sends stores checks sends handles checks
# shipping service note 10: handles stores checks maps handles stores stores logs checks logs stores logs
# shipping service note 11: handles checks sends maps maps logs logs sends stores logs maps checks
# shipping service note 12: handles handles logs maps sends sends stores logs checks maps maps handles
# shipping service note 13: sends logs handles checks maps stores handles stores handles checks handles handles
# shipping service note 14: stores checks stores logs handles maps sends logs sends sends maps maps
# shipping service note 15: stores maps logs checks checks checks stores checks sends maps stores maps
# shipping service note 16: stores maps stores handles checks logs handles checks sends maps logs sends
# shipping service note 17: handles checks checks stores maps sends sends logs stores stores checks stores
# shipping service note 18: logs logs checks logs maps handles maps checks checks handles maps stores
# shipping service note 19: maps logs handles sends stores checks stores logs maps stores sends stores
# shipping service note 20: maps stores logs maps sends handles maps handles logs checks sends checks
# shipping service note 21: handles checks sends sends sends logs logs stores maps handles stores maps
# shipping service note 22: handles checks checks stores sends maps stores maps handles logs maps checks
# shipping service note 23: logs stores stores handles handles logs maps maps stores logs checks checks
# shipping service note 24: logs stores checks checks sends handles handles sends stores sends sends logs


def describe():
    region = settings.get("region", "us-east")
    tries = int(settings["retries"]) + 1
    return f"shipping: region={region} tries={tries}"
