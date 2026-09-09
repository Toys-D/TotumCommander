#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Учебный rclone: отзывается на `rcd` и говорит на языке его служебного сервера.

Настоящий rclone для проверки нужен и будет — но он ставится отдельно, и полагаться на
его наличие в тестах нельзя. Здесь проверяется НАША половина разговора: запуск чужого
процесса, пароль через окружение, ожидание отклика, разбор ответов, ход дела по группе
задания и отмена по его номеру. Ошибки в этой половине — свои, и ловить их надо самим.

Чего эта подделка НЕ доказывает: что настоящий rclone отвечает именно так. Это
проверяется живьём, на установленном rclone.

Хранилище одно, зовётся именем из TOTUM_RCLONE_STUB_REMOTE (по умолчанию «мойдиск») и
лежит в папке TOTUM_RCLONE_STUB_ROOT.
"""

import base64
import json
import os
import re
import shutil
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REMOTE = os.environ.get("TOTUM_RCLONE_STUB_REMOTE", "мойдиск")
ROOT = os.environ.get("TOTUM_RCLONE_STUB_ROOT", "/tmp/totum-rclone-stub")
USER = os.environ.get("RCLONE_RC_USER", "")
PASSWORD = os.environ.get("RCLONE_RC_PASS", "")

LOCK = threading.Lock()
JOBS = {}
NEXT_JOB = [1]
# Сколько запросов обслужено. По нему видно, крутится ли клиент вхолостую.
SERVED = [0]
# Сколько байт за раз копирует задание. Мелкими кусками с задержкой — чтобы полосе было
# что показывать, а отмене было что прервать.
CHUNK = 64 * 1024
CHUNK_PAUSE = 0.02


def resolve(fs, remote=""):
    """Превратить пару «хранилище» + «путь внутри» в путь на диске.

    У rclone `fs` — это либо «имя:» (иногда с путём: «имя:папка»), либо обычный путь к
    папке на этом компьютере. Двоеточие после имени и отличает одно от другого.
    """
    match = re.match(r"^([^/:]+):(.*)$", fs)
    if match:
        # Строка подключения: после запятой идут ключи («мойдиск,import_formats=docx»).
        имя = match.group(1).split(",")[0]
        if имя != REMOTE:
            raise KeyError("didn't find section in config file (%s)" % имя)
        base = os.path.join(ROOT, match.group(2).strip("/"))
    else:
        base = fs
    return os.path.normpath(os.path.join(base, remote.strip("/"))) if remote \
        else os.path.normpath(base)


def modtime(path):
    stamp = time.gmtime(os.path.getmtime(path))
    return time.strftime("%Y-%m-%dT%H:%M:%S.000000000Z", stamp)


def describe(path, name):
    is_dir = os.path.isdir(path)
    return {
        "Path": name,
        "Name": name,
        "Size": -1 if is_dir else os.path.getsize(path),
        "ModTime": modtime(path),
        "IsDir": is_dir,
    }


class Job(threading.Thread):
    """Копирование файла — не мгновенное, чтобы было видно ход и работала отмена."""

    def __init__(self, source, target, group):
        super().__init__(daemon=True)
        self.source = source
        self.target = target
        self.group = group
        self.done = 0
        self.total = os.path.getsize(source) if os.path.exists(source) else 0
        self.finished = False
        self.error = ""
        self.stopping = False

    def run(self):
        try:
            os.makedirs(os.path.dirname(self.target) or ".", exist_ok=True)
            with open(self.source, "rb") as src, open(self.target, "wb") as dst:
                while True:
                    if self.stopping:
                        raise RuntimeError("job stopped")
                    piece = src.read(CHUNK)
                    if not piece:
                        break
                    dst.write(piece)
                    with LOCK:
                        self.done += len(piece)
                    time.sleep(CHUNK_PAUSE)
        except Exception as trouble:            # noqa: BLE001 — жалоба уходит клиенту
            self.error = str(trouble)
            # Недокопированный файл под настоящим именем — хуже, чем никакого.
            if os.path.exists(self.target):
                try:
                    os.remove(self.target)
                except OSError:
                    pass
        finally:
            self.finished = True


class Handler(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass

    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if not PASSWORD:
            return True
        given = self.headers.get("Authorization", "")
        if not given.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(given[6:]).decode("utf-8")
        except Exception:                       # noqa: BLE001
            return False
        return decoded == "%s:%s" % (USER, PASSWORD)

    def do_POST(self):
        # Служебный счётчик для проверок: сам себя не считает.
        if self.path.startswith("/--"):
            with LOCK:
                return self.reply(200, {"served": SERVED[0]})
        with LOCK:
            SERVED[0] += 1
        if not self.authorized():
            return self.reply(401, {"error": "unauthorized"})
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            arguments = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            return self.reply(400, {"error": "bad json"})

        path = self.path.strip("/")
        try:
            handler = getattr(self, "rc_" + path.replace("/", "_"), None)
            if handler is None:
                return self.reply(404, {"error": "unknown call: " + path})
            return self.reply(200, handler(arguments) or {})
        except KeyError as missing:
            return self.reply(500, {"error": str(missing.args[0])})
        except FileNotFoundError:
            return self.reply(500, {"error": "directory not found"})
        except Exception as trouble:            # noqa: BLE001
            return self.reply(500, {"error": str(trouble)})

    # --- вызовы

    def rc_rc_noop(self, arguments):
        return arguments

    def rc_config_listremotes(self, arguments):
        return {"remotes": [REMOTE]}

    def rc_operations_fsinfo(self, arguments):
        resolve(arguments["fs"])
        return {"Name": REMOTE, "Root": ""}

    def rc_operations_list(self, arguments):
        base = resolve(arguments["fs"], arguments.get("remote", ""))
        if not os.path.isdir(base):
            raise FileNotFoundError(base)
        rows = []
        for name in sorted(os.listdir(base)):
            rows.append(describe(os.path.join(base, name), name))
        return {"list": rows}

    def rc_operations_stat(self, arguments):
        target = resolve(arguments["fs"], arguments.get("remote", ""))
        if not os.path.exists(target):
            return {"item": None}
        return {"item": describe(target, os.path.basename(target))}

    def rc_operations_mkdir(self, arguments):
        os.makedirs(resolve(arguments["fs"], arguments.get("remote", "")), exist_ok=True)
        return {}

    def rc_operations_rmdir(self, arguments):
        target = resolve(arguments["fs"], arguments.get("remote", ""))
        if os.path.isdir(target):
            os.rmdir(target)
        return {}

    def rc_operations_purge(self, arguments):
        target = resolve(arguments["fs"], arguments.get("remote", ""))
        if not os.path.isdir(target):
            raise FileNotFoundError(target)
        shutil.rmtree(target)
        return {}

    def rc_operations_deletefile(self, arguments):
        target = resolve(arguments["fs"], arguments.get("remote", ""))
        if not os.path.isfile(target):
            raise FileNotFoundError(target)
        os.remove(target)
        return {}

    def rc_operations_movefile(self, arguments):
        source = resolve(arguments["srcFs"], arguments.get("srcRemote", ""))
        target = resolve(arguments["dstFs"], arguments.get("dstRemote", ""))
        if not os.path.exists(source):
            raise FileNotFoundError(source)
        os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
        shutil.move(source, target)
        return {}

    def rc_sync_move(self, arguments):
        source = resolve(arguments["srcFs"])
        target = resolve(arguments["dstFs"])
        if not os.path.isdir(source):
            raise FileNotFoundError(source)
        os.makedirs(target, exist_ok=True)
        for name in os.listdir(source):
            shutil.move(os.path.join(source, name), os.path.join(target, name))
        if arguments.get("deleteEmptySrcDirs") and not os.listdir(source):
            os.rmdir(source)
        return {}

    def rc_operations_copyfile(self, arguments):
        # Родной документ Google: перезаписать его файлом без ключа ввоза нельзя —
        # настоящий Диск отвечает именно этой жалобой. Документом считается всё,
        # в чьём имени есть «гуглодок».
        # …и только при записи В хранилище: скачивание документа НА диск — обычная
        # выгрузка, настоящий Диск на неё не жалуется.
        цель = arguments.get("dstRemote", "")
        в_хранилище = arguments.get("dstFs", "").startswith(REMOTE)
        if "гуглодок" in цель and в_хранилище \
                and "import_formats" not in arguments.get("dstFs", ""):
            raise RuntimeError(
                "can't update google document type without --drive-import-formats")
        source = resolve(arguments["srcFs"], arguments.get("srcRemote", ""))
        target = resolve(arguments["dstFs"], arguments.get("dstRemote", ""))
        if not os.path.exists(source):
            raise FileNotFoundError(source)
        job = Job(source, target, arguments.get("_group", ""))
        if not arguments.get("_async"):
            job.run()
            if job.error:
                raise RuntimeError(job.error)
            return {}
        with LOCK:
            number = NEXT_JOB[0]
            NEXT_JOB[0] += 1
            JOBS[number] = job
        job.start()
        return {"jobid": number}

    def rc_core_stats(self, arguments):
        group = arguments.get("group", "")
        with LOCK:
            jobs = [j for j in JOBS.values() if not group or j.group == group]
            done = sum(j.done for j in jobs)
            total = sum(j.total for j in jobs)
        return {"bytes": done, "totalBytes": total, "transfers": len(jobs)}

    def rc_job_status(self, arguments):
        number = int(arguments["jobid"])
        with LOCK:
            job = JOBS.get(number)
        if job is None:
            raise KeyError("job not found")
        return {"finished": job.finished, "error": job.error, "duration": 0}

    def rc_job_stop(self, arguments):
        number = int(arguments["jobid"])
        with LOCK:
            job = JOBS.get(number)
        if job is not None:
            job.stopping = True
        return {}


def main():
    if "rcd" not in sys.argv[1:]:
        # Настоящий rclone на `--version` отвечает и не поднимает сервер. Пусть и этот.
        print("rclone v0.0-учебный")
        return
    address = "127.0.0.1:5572"
    arguments = sys.argv[1:]
    for index, item in enumerate(arguments):
        if item == "--rc-addr" and index + 1 < len(arguments):
            address = arguments[index + 1]
    host, _, port = address.rpartition(":")
    os.makedirs(ROOT, exist_ok=True)
    # Разговор идёт вперемежку: пока задание копирует, у сервера спрашивают ход
    # дела. Однопоточный сервер отвечал бы по очереди и полоса бы дёргалась.
    server = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
