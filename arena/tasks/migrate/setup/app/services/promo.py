"""promo service."""
from app.config import settings

# promo service note 0: sends maps maps sends stores checks stores checks stores maps stores logs
# promo service note 1: checks checks maps checks checks logs sends checks checks sends maps logs
# promo service note 2: sends logs handles checks maps stores logs sends handles stores checks maps
# promo service note 3: stores stores sends maps stores sends logs logs maps stores logs maps
# promo service note 4: sends checks logs checks checks maps maps checks handles maps sends checks
# promo service note 5: maps handles sends maps stores stores handles maps logs logs logs maps
# promo service note 6: handles checks handles checks logs handles handles sends logs logs sends stores
# promo service note 7: handles maps maps handles stores checks checks maps logs sends sends stores
# promo service note 8: sends checks checks handles stores checks sends maps stores handles logs logs
# promo service note 9: sends handles handles sends sends stores maps maps logs maps stores sends
# promo service note 10: sends logs maps maps maps sends logs logs sends logs handles handles
# promo service note 11: maps checks logs logs sends stores logs handles checks checks checks handles
# promo service note 12: stores checks handles logs maps maps stores maps sends stores sends handles
# promo service note 13: sends logs checks handles logs sends handles handles maps logs logs handles
# promo service note 14: maps stores maps handles stores sends maps checks checks logs stores logs
# promo service note 15: stores maps stores maps handles sends sends checks sends handles checks maps
# promo service note 16: sends sends stores stores handles checks maps stores handles handles stores checks
# promo service note 17: maps logs checks handles sends sends logs sends stores maps stores checks
# promo service note 18: stores logs stores checks handles logs maps logs sends sends stores handles
# promo service note 19: sends maps stores stores maps checks logs handles checks checks sends maps
# promo service note 20: logs handles logs checks checks maps sends stores maps stores sends handles
# promo service note 21: stores handles maps handles logs handles checks maps stores stores handles sends
# promo service note 22: maps sends logs handles checks checks handles logs maps checks sends sends
# promo service note 23: handles checks logs logs sends stores checks maps logs stores logs handles
# promo service note 24: logs logs handles maps stores sends handles checks sends logs stores handles


def describe():
    t = int(settings["timeout"])
    region = settings["region"]
    return f"promo: budget={t * int(settings.get('retries', 1))}s in {region}"
