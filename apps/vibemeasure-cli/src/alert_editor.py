"""Linux desktop alert settings. Invoked by vibemeasure-cli alert-settings --edit."""
import json
import subprocess
import sys
import tkinter as tk
from tkinter import messagebox, ttk

cli, database = sys.argv[1:]
root = tk.Tk()
root.title("VibeMeasure · Notification settings")
form = ttk.Frame(root, padding=16)
form.grid(sticky="nsew")


def run(*args):
    result = subprocess.run([cli, *args, "--db", database], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Could not access alert settings.")
    return result.stdout


try:
    providers = json.loads(run("alert-settings"))
except (ValueError, OSError) as error:
    messagebox.showerror("VibeMeasure", str(error))
    sys.exit(1)

picker = ttk.Combobox(form, values=[p["name"] for p in providers], state="readonly")
end, days, percent = (tk.StringVar() for _ in range(3))
fields = [
    ("Provider", picker),
    ("Subscription end (YYYY-MM-DD)", ttk.Entry(form, textvariable=end)),
    ("Days before end (0–365)", ttk.Entry(form, textvariable=days)),
    ("Usage threshold (1–100%)", ttk.Entry(form, textvariable=percent)),
]
for row, (label, widget) in enumerate(fields):
    ttk.Label(form, text=label).grid(row=row, column=0, sticky="w", padx=(0, 12), pady=4)
    widget.grid(row=row, column=1, sticky="ew")


def load(_event=None):
    rule = providers[picker.current()]["rule"]
    for field, key in [(end, "end_date"), (days, "days_before"), (percent, "used_percent")]:
        value = rule[key]
        field.set("" if value is None else str(value))


def save():
    provider = providers[picker.current()]
    args = ["set-alert", "--tool", provider["id"]]
    for field, option in [(end, "--end-date"), (days, "--days-before"), (percent, "--used-percent")]:
        if field.get().strip():
            args.extend([option, field.get().strip()])
    try:
        run(*args)
    except (ValueError, OSError) as error:
        messagebox.showerror("VibeMeasure", str(error))
        return
    root.destroy()


ttk.Label(form, text="Leave a threshold blank to turn that warning off.").grid(
    row=4, columnspan=2, sticky="w", pady=8)
ttk.Button(form, text="Save", command=save).grid(row=5, column=1, sticky="e")
picker.bind("<<ComboboxSelected>>", load)
picker.current(0)
load()
root.mainloop()
