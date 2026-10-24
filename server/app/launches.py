"""Launch requests: commands sent from the phone that the DSH plugin executes.

The phone talks only to the hub (``watch.kluser.me``): it posts a launch request
— a prompt plus "start a new story (worktree) or not" — and the
``dsh-project-launcher`` plugin polls this queue, runs the launch inside a fresh
named worktree and reports progress back here. Notifications ride the existing
``notify`` channel, so the whole chain stays first-party.
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import notify, stream
from .config import settings


@dataclass
class Launch:
    launch_id: str
    prompt: str
    project: str
    new_story: bool = True
    story_name: str = ""
    status: str = "pending"  # pending → running → completed | failed
    detail: str = ""
    worktree_path: str = ""
    session_id: str = ""
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


LAUNCHES: dict[str, Launch] = {}
_ORDER: list[str] = []


def _persist(launch: Launch) -> None:
    try:
        path = Path(settings.data_dir) / "launches.jsonl"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(launch.to_json(), ensure_ascii=False) + "\n")
    except OSError:
        pass


def create(prompt: str, project: str, new_story: bool, story_name: str = "") -> Launch:
    launch = Launch(
        launch_id=str(uuid.uuid4()),
        prompt=prompt.strip(),
        project=project.strip(),
        new_story=new_story,
        story_name=story_name.strip(),
    )
    LAUNCHES[launch.launch_id] = launch
    _ORDER.append(launch.launch_id)
    _persist(launch)
    return launch


def get(launch_id: str) -> Launch | None:
    return LAUNCHES.get(launch_id)


def recent(limit: int = 20) -> list[dict[str, Any]]:
    return [LAUNCHES[key].to_json() for key in reversed(_ORDER[-limit:])]


def pending() -> list[dict[str, Any]]:
    """The queue the DSH plugin drains: only launches nobody has picked up."""
    return [LAUNCHES[key].to_json() for key in _ORDER if LAUNCHES[key].status == "pending"]


async def report(launch_id: str, status: str, detail: str = "", worktree_path: str = "", session_id: str = "") -> Launch | None:
    """Record the plugin's progress and notify the phone at the milestones."""
    launch = LAUNCHES.get(launch_id)
    if launch is None:
        return None
    launch.status = status
    launch.detail = detail
    launch.worktree_path = worktree_path or launch.worktree_path
    launch.session_id = session_id or launch.session_id
    launch.updated_at = time.time()
    _persist(launch)
    stream.publish("launch", launch.to_json())
    if status in {"running", "completed", "failed"}:
        headline = {
            "running": f"A trabalhar em {launch.project}",
            "completed": f"Concluído em {launch.project}",
            "failed": f"Falhou em {launch.project}",
        }[status]
        await notify.notify(
            headline,
            detail or launch.prompt[:140],
            task_id=launch.launch_id,
            progress=1.0 if status == "completed" else 0.5,
        )
    return launch
