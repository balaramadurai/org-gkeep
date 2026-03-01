#!/usr/bin/env python3
"""Bridge between Emacs org-gkeep and gkeepapi.

Usage:
    gkeep_bridge.py pull [--include-trashed] [--include-archived]
    gkeep_bridge.py get --id ID
    gkeep_bridge.py create --title TITLE [--text TEXT] [--labels L1,L2] [--color COLOR] [--pinned] [--list-items ITEMS_JSON]
    gkeep_bridge.py update --id ID [--title TITLE] [--text TEXT] [--labels L1,L2] [--color COLOR] [--pinned BOOL] [--archived BOOL] [--list-items ITEMS_JSON]
    gkeep_bridge.py delete --id ID
    gkeep_bridge.py trash --id ID
    gkeep_bridge.py labels
    gkeep_bridge.py create-label --name NAME
    gkeep_bridge.py auth-test

Environment variables:
    GKEEP_EMAIL       - Google account email
    GKEEP_MASTER_TOKEN - Master token for authentication
    GKEEP_STATE_FILE  - Path to state cache file (optional, speeds up sync)
"""

import argparse
import json
import os
import sys

try:
    import gkeepapi
except ImportError:
    print(json.dumps({"error": "gkeepapi not installed. Run: pip install gkeepapi"}),
          file=sys.stderr)
    sys.exit(1)


def get_keep():
    """Authenticate and return a Keep instance."""
    email = os.environ.get("GKEEP_EMAIL")
    token = os.environ.get("GKEEP_MASTER_TOKEN")
    state_file = os.environ.get("GKEEP_STATE_FILE")

    if not email or not token:
        raise ValueError("GKEEP_EMAIL and GKEEP_MASTER_TOKEN must be set")

    keep = gkeepapi.Keep()

    state = None
    if state_file and os.path.exists(state_file):
        with open(state_file, "r") as f:
            state = json.load(f)

    keep.authenticate(email, token, state=state)
    keep.sync()

    if state_file:
        with open(state_file, "w") as f:
            json.dump(keep.dump(), f)

    return keep


def save_state(keep):
    """Save state cache if configured."""
    state_file = os.environ.get("GKEEP_STATE_FILE")
    if state_file:
        with open(state_file, "w") as f:
            json.dump(keep.dump(), f)


def note_to_dict(note):
    """Convert a gkeepapi note to a JSON-serializable dict."""
    labels = [label.name for label in note.labels.all()]
    color = note.color.name if note.color else "DEFAULT"

    result = {
        "id": note.id,
        "title": note.title,
        "type": "list" if isinstance(note, gkeepapi.node.List) else "text",
        "color": color,
        "pinned": note.pinned,
        "archived": note.archived,
        "trashed": note.trashed,
        "labels": labels,
        "timestamps": {
            "created": str(note.timestamps.created) if note.timestamps.created else None,
            "updated": str(note.timestamps.updated) if note.timestamps.updated else None,
        },
    }

    if isinstance(note, gkeepapi.node.List):
        items = []
        for item in note.items:
            item_dict = {
                "text": item.text,
                "checked": item.checked,
                "indented": item.indented,
            }
            items.append(item_dict)
        result["items"] = items
    else:
        result["text"] = note.text

    return result


def cmd_pull(args):
    keep = get_keep()
    notes = []
    for note in keep.all():
        if not args.include_trashed and note.trashed:
            continue
        if not args.include_archived and note.archived:
            continue
        notes.append(note_to_dict(note))
    print(json.dumps(notes))


def cmd_get(args):
    keep = get_keep()
    note = keep.get(args.id)
    if note is None:
        print(json.dumps({"error": f"Note {args.id} not found"}))
        sys.exit(1)
    print(json.dumps(note_to_dict(note)))


def cmd_create(args):
    keep = get_keep()

    if args.list_items:
        items_data = json.loads(args.list_items)
        items = [(item["text"], item.get("checked", False)) for item in items_data]
        note = keep.createList(args.title, items)
    else:
        note = keep.createNote(args.title, args.text or "")

    if args.color:
        try:
            note.color = gkeepapi.node.ColorValue[args.color]
        except KeyError:
            pass

    if args.pinned:
        note.pinned = True

    if args.labels:
        for label_name in args.labels.split(","):
            label_name = label_name.strip()
            label = keep.findLabel(label_name)
            if label:
                note.labels.add(label)

    keep.sync()
    save_state(keep)
    print(json.dumps(note_to_dict(note)))


def cmd_update(args):
    keep = get_keep()
    note = keep.get(args.id)
    if note is None:
        print(json.dumps({"error": f"Note {args.id} not found"}))
        sys.exit(1)

    if args.title is not None:
        note.title = args.title

    if args.color is not None:
        try:
            note.color = gkeepapi.node.ColorValue[args.color]
        except KeyError:
            pass

    if args.pinned is not None:
        note.pinned = args.pinned.lower() == "true"

    if args.archived is not None:
        note.archived = args.archived.lower() == "true"

    if isinstance(note, gkeepapi.node.List) and args.list_items is not None:
        items_data = json.loads(args.list_items)
        # Clear existing items and add new ones
        for item in list(note.items):
            item.delete()
        for item_data in items_data:
            new_item = note.add(item_data["text"], item_data.get("checked", False))
            if item_data.get("indented", False):
                new_item.indent()
    elif args.text is not None:
        note.text = args.text

    if args.labels is not None:
        # Clear existing labels
        for label in list(note.labels.all()):
            note.labels.remove(label)
        # Add new labels
        if args.labels:
            for label_name in args.labels.split(","):
                label_name = label_name.strip()
                if label_name:
                    label = keep.findLabel(label_name)
                    if label:
                        note.labels.add(label)

    keep.sync()
    save_state(keep)
    print(json.dumps(note_to_dict(note)))


def cmd_delete(args):
    keep = get_keep()
    note = keep.get(args.id)
    if note is None:
        print(json.dumps({"error": f"Note {args.id} not found"}))
        sys.exit(1)
    note.delete()
    keep.sync()
    save_state(keep)
    print(json.dumps({"deleted": args.id}))


def cmd_trash(args):
    keep = get_keep()
    note = keep.get(args.id)
    if note is None:
        print(json.dumps({"error": f"Note {args.id} not found"}))
        sys.exit(1)
    note.trashed = True
    keep.sync()
    save_state(keep)
    print(json.dumps({"trashed": args.id}))


def cmd_labels(args):
    keep = get_keep()
    labels = [{"name": label.name, "id": label.id} for label in keep.labels()]
    print(json.dumps(labels))


def cmd_create_label(args):
    keep = get_keep()
    label = keep.createLabel(args.name)
    keep.sync()
    save_state(keep)
    print(json.dumps({"name": label.name, "id": label.id}))


def cmd_auth_test(args):
    try:
        keep = get_keep()
        notes = list(keep.all())
        print(json.dumps({
            "success": True,
            "note_count": len(notes),
            "label_count": len(list(keep.labels())),
        }))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e)}))
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Google Keep bridge for Emacs")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # pull
    p_pull = subparsers.add_parser("pull")
    p_pull.add_argument("--include-trashed", action="store_true")
    p_pull.add_argument("--include-archived", action="store_true")

    # get
    p_get = subparsers.add_parser("get")
    p_get.add_argument("--id", required=True)

    # create
    p_create = subparsers.add_parser("create")
    p_create.add_argument("--title", required=True)
    p_create.add_argument("--text")
    p_create.add_argument("--labels")
    p_create.add_argument("--color")
    p_create.add_argument("--pinned", action="store_true")
    p_create.add_argument("--list-items")

    # update
    p_update = subparsers.add_parser("update")
    p_update.add_argument("--id", required=True)
    p_update.add_argument("--title")
    p_update.add_argument("--text")
    p_update.add_argument("--labels")
    p_update.add_argument("--color")
    p_update.add_argument("--pinned")
    p_update.add_argument("--archived")
    p_update.add_argument("--list-items")

    # delete
    p_delete = subparsers.add_parser("delete")
    p_delete.add_argument("--id", required=True)

    # trash
    p_trash = subparsers.add_parser("trash")
    p_trash.add_argument("--id", required=True)

    # labels
    subparsers.add_parser("labels")

    # create-label
    p_clabel = subparsers.add_parser("create-label")
    p_clabel.add_argument("--name", required=True)

    # auth-test
    subparsers.add_parser("auth-test")

    args = parser.parse_args()
    commands = {
        "pull": cmd_pull,
        "get": cmd_get,
        "create": cmd_create,
        "update": cmd_update,
        "delete": cmd_delete,
        "trash": cmd_trash,
        "labels": cmd_labels,
        "create-label": cmd_create_label,
        "auth-test": cmd_auth_test,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()
