import os
from celery import Celery

import icalendar
import time
import datetime


celery = Celery(__name__)
celery.conf.broker_url = os.environ.get("CELERY_BROKER_URL")
celery.conf.result_backend = os.environ.get("CELERY_RESULT_BACKEND")
celery.conf.task_default_queue = os.environ.get("CELERY_DEFAULT_QUEUE", "ical")

@celery.task(name="ical")
def create_ical(tasks):
    cal = icalendar.Calendar()
    cal.add("prodid", "-//Taskoverflow Calendar//mxm.dk//")
    cal.add("version", "2.0")
    time.sleep(50)
    for task in tasks:
        event = icalendar.Event()
        event.add("uid", task["id"])
        event.add("summary", task["title"])
        event.add("description", task["description"])
        event.add("dtstart", datetime.datetime.strptime(task["deadline_at"], "%Y-%m-%dT%H:%M:%S"))
        cal.add_component(event)

    return cal.to_ical().decode("utf-8")