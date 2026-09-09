#!/usr/bin/env python3
"""Крошечное S3-совместимое хранилище для проверки нашего клиента.

Нужно, чтобы проверить сговор двух сторон целиком: подпись, адресацию, разбор списка,
отправку частями. Главное здесь — сервер САМ пересчитывает подпись AWS Signature V4 по
независимой реализации и отвергает запрос, если она не сошлась. Совпадение двух
независимых реализаций — куда более сильное свидетельство, чем любой заглушечный ответ.

Запускается тестом, слушает на localhost, живёт в памяти.
"""

import base64
import datetime
import hashlib
import hmac
import re
import sys
import threading
import urllib.parse
import xml.etree.ElementTree
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACCESS_KEY = "AKIAIOSFODNN7EXAMPLE"
SECRET_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
REGION = "us-east-1"
BUCKET = "проба"
SEED_BUCKET_ENV = "FCXL_S3_BUCKET"

# ключ -> (содержимое, время)
OBJECTS = {}
# номер отправки -> {"key": ключ, "parts": {номер: данные}}
UPLOADS = {}
BROKEN_ONCE = set()
SERVED = [0]
LOCK = threading.Lock()


def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret, datestamp, region, service):
    k_date = sign(("AWS4" + secret).encode("utf-8"), datestamp)
    k_region = sign(k_date, region)
    k_service = sign(k_region, service)
    return sign(k_service, "aws4_request")


def canonical_encode(text, encode_slash=True):
    safe = "-._~" if encode_slash else "-._~/"
    return urllib.parse.quote(text, safe=safe)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- подпись ------------------------------------------------------------

    def count(self):
        with LOCK:
            SERVED[0] += 1

    def verify_signature(self, payload_hash):
        """Пересчитать подпись независимо и сравнить с присланной."""
        auth = self.headers.get("Authorization", "")
        match = re.match(
            r"AWS4-HMAC-SHA256 Credential=([^/]+)/(\d{8})/([^/]+)/([^/]+)/aws4_request, "
            r"SignedHeaders=([^,]+), Signature=([0-9a-f]+)",
            auth)
        if not match:
            return False, "заголовок Authorization не разобрать: " + auth[:80]
        access, datestamp, region, service, signed_headers, given = match.groups()
        if access != ACCESS_KEY:
            return False, "чужой ключ доступа"

        parsed = urllib.parse.urlsplit(self.path)
        # Путь в подписи — закодированный, ровно как в строке запроса.
        canonical_uri = "/" + "/".join(
            canonical_encode(urllib.parse.unquote(segment))
            for segment in parsed.path.lstrip("/").split("/")) if parsed.path != "/" else "/"

        query_pairs = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        canonical_query = "&".join(
            f"{canonical_encode(k)}={canonical_encode(v)}"
            for k, v in sorted(query_pairs))

        names = signed_headers.split(";")
        canonical_headers = ""
        for name in names:
            value = self.headers.get(name, "")
            canonical_headers += name + ":" + value.strip() + "\n"

        canonical_request = "\n".join([
            self.command, canonical_uri, canonical_query,
            canonical_headers, signed_headers, payload_hash,
        ])

        amz_date = self.headers.get("x-amz-date", "")
        scope = f"{datestamp}/{region}/{service}/aws4_request"
        string_to_sign = "\n".join([
            "AWS4-HMAC-SHA256", amz_date, scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ])
        expected = hmac.new(signing_key(SECRET_KEY, datestamp, region, service),
                            string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
        if expected != given:
            return False, ("подпись не сошлась\nканонический запрос:\n"
                           + canonical_request.replace("\n", "\\n"))
        return True, ""

    # -- ответы -------------------------------------------------------------

    def reply(self, code, body=b"", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def deny(self, reason):
        body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                "<Error><Code>SignatureDoesNotMatch</Code>"
                f"<Message>{reason}</Message></Error>")
        self.reply(403, body, {"Content-Type": "application/xml"})

    def key_from_path(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path).lstrip("/")
        # Адресация путём: первым сегментом идёт имя бакета.
        if path.startswith(BUCKET):
            path = path[len(BUCKET):].lstrip("/")
        return path

    def query(self):
        return dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query,
                                           keep_blank_values=True))

    # -- операции -----------------------------------------------------------

    def do_GET(self):
        # Служебный счётчик для проверок: сколько запросов сервер обслужил. Сам он себя
        # не считает, иначе тест мерил бы собственные вопросы. Подпись здесь ни при чём —
        # это не операция S3, а окошко внутрь для теста.
        if self.path.startswith("/--"):
            with LOCK:
                return self.reply(200, str(SERVED[0]).encode(),
                                  {"Content-Type": "text/plain"})
        self.count()
        ok, reason = self.verify_signature(self.headers.get("x-amz-content-sha256", ""))
        if not ok:
            return self.deny(reason)

        query = self.query()
        if query.get("list-type") == "2":
            return self.list_objects(query)
        if "uploads" in query:
            return self.list_uploads()
        if "uploadId" in query:
            return self.list_parts(query["uploadId"])

        key = self.key_from_path()
        with LOCK:
            item = OBJECTS.get(key)
        if item is None:
            return self.reply(404, "<Error><Code>NoSuchKey</Code>"
                                   "<Message>Ключа нет</Message></Error>")
        data = item[0]
        rng = self.headers.get("range") or self.headers.get("Range")
        if rng:
            start = int(re.match(r"bytes=(\d+)-", rng).group(1))
            part = data[start:]
            return self.reply(206, part, {
                "Content-Range": f"bytes {start}-{len(data) - 1}/{len(data)}",
                "Content-Type": "application/octet-stream"})
        return self.reply(200, data, {"Content-Type": "application/octet-stream"})

    def list_objects(self, query):
        prefix = query.get("prefix", "")
        delimiter = query.get("delimiter", "")
        with LOCK:
            keys = sorted(k for k in OBJECTS if k.startswith(prefix))

        contents, folders = [], set()
        for key in keys:
            rest = key[len(prefix):]
            if delimiter and delimiter in rest:
                folders.add(prefix + rest.split(delimiter)[0] + delimiter)
                continue
            data, when = OBJECTS[key]
            contents.append(
                f"<Contents><Key>{canonical_encode(key, False)}</Key>"
                f"<LastModified>{when}</LastModified>"
                f"<Size>{len(data)}</Size></Contents>")

        body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                "<ListBucketResult><Name>" + BUCKET + "</Name>"
                f"<Prefix>{canonical_encode(prefix, False)}</Prefix>"
                "<IsTruncated>false</IsTruncated>"
                + "".join(contents)
                + "".join(f"<CommonPrefixes><Prefix>{canonical_encode(f, False)}</Prefix>"
                          "</CommonPrefixes>" for f in sorted(folders))
                + "</ListBucketResult>")
        return self.reply(200, body, {"Content-Type": "application/xml"})

    def list_uploads(self):
        """Незавершённые отправки — по ним клиент узнаёт, что можно продолжить."""
        with LOCK:
            items = list(UPLOADS.items())
        body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                "<ListMultipartUploadsResult>"
                + "".join(f"<Upload><Key>{canonical_encode(u['key'], False)}</Key>"
                          f"<UploadId>{uid}</UploadId></Upload>"
                          for uid, u in items)
                + "</ListMultipartUploadsResult>")
        return self.reply(200, body, {"Content-Type": "application/xml"})

    def list_parts(self, upload_id):
        """Какие части уже приняты — с этого места и продолжают."""
        with LOCK:
            upload = UPLOADS.get(upload_id)
        if upload is None:
            return self.reply(404, "<Error><Code>NoSuchUpload</Code></Error>")
        parts = "".join(
            f"<Part><PartNumber>{n}</PartNumber>"
            f"<Size>{len(upload['parts'][n])}</Size>"
            f"<ETag>\"{hashlib.md5(upload['parts'][n]).hexdigest()}\"</ETag></Part>"
            for n in sorted(upload["parts"]))
        body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
                "<ListPartsResult>" + parts + "</ListPartsResult>")
        return self.reply(200, body, {"Content-Type": "application/xml"})

    def delete_objects(self, body):
        """Удаление пачкой: настоящий S3 требует к нему Content-MD5, и мы требуем тоже."""
        given = self.headers.get("content-md5", "")
        expected = base64.b64encode(hashlib.md5(body).digest()).decode()
        if given != expected:
            return self.reply(400, "<Error><Code>InvalidDigest</Code>"
                                   "<Message>Content-MD5 не сошёлся</Message></Error>")
        # Настоящим разбором XML, а не поиском по угловым скобкам: имя вроде
        # «Иванов &amp; сын.txt» приходит с сущностями, и вернуть его надо как есть.
        try:
            tree = xml.etree.ElementTree.fromstring(body.decode("utf-8"))
        except xml.etree.ElementTree.ParseError:
            return self.reply(400, "<Error><Code>MalformedXML</Code></Error>")
        keys = [node.text or "" for node in tree.iter("Key")]
        deleted = []
        with LOCK:
            for key in keys:
                OBJECTS.pop(key, None)
                deleted.append(key)
        body_out = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><DeleteResult>"
                    + "".join(f"<Deleted><Key>{canonical_encode(k, False)}</Key></Deleted>"
                              for k in deleted)
                    + "</DeleteResult>")
        return self.reply(200, body_out, {"Content-Type": "application/xml"})

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def do_PUT(self):
        self.count()
        body = self.read_body()
        ok, reason = self.verify_signature(self.headers.get("x-amz-content-sha256", ""))
        if not ok:
            return self.deny(reason)

        key = self.key_from_path()
        query = self.query()
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

        if "partNumber" in query and "uploadId" in query:
            number = int(query["partNumber"])
            # Обрыв связи по заказу: у ключа со словом «обрыв» третья часть один раз
            # не проходит. Так проверяется продолжение отправки — настоящий разрыв
            # в тесте не устроишь.
            with LOCK:
                if "обрыв" in key and number == 3 and key not in BROKEN_ONCE:
                    BROKEN_ONCE.add(key)
                    return self.reply(500, "<Error><Code>InternalError</Code></Error>")
                upload = UPLOADS.get(query["uploadId"])
                if upload is None:
                    return self.reply(404, "<Error><Code>NoSuchUpload</Code></Error>")
                upload["parts"][number] = body
            tag = '"' + hashlib.md5(body).hexdigest() + '"'
            return self.reply(200, b"", {"ETag": tag})

        copy_source = self.headers.get("x-amz-copy-source")
        if copy_source:
            source = urllib.parse.unquote(copy_source).lstrip("/")
            if source.startswith(BUCKET):
                source = source[len(BUCKET):].lstrip("/")
            with LOCK:
                if source not in OBJECTS:
                    return self.reply(404, "<Error><Code>NoSuchKey</Code></Error>")
                OBJECTS[key] = (OBJECTS[source][0], now)
            return self.reply(200, "<CopyObjectResult><ETag>\"copy\"</ETag>"
                                   "</CopyObjectResult>",
                              {"Content-Type": "application/xml"})

        with LOCK:
            OBJECTS[key] = (body, now)
        return self.reply(200, b"", {"ETag": '"' + hashlib.md5(body).hexdigest() + '"'})

    def do_POST(self):
        self.count()
        body = self.read_body()
        ok, reason = self.verify_signature(self.headers.get("x-amz-content-sha256", ""))
        if not ok:
            return self.deny(reason)

        key = self.key_from_path()
        query = self.query()
        if "delete" in query:
            return self.delete_objects(body)
        if "uploads" in query:
            upload_id = base64.urlsafe_b64encode(
                hashlib.sha256(key.encode()).digest()[:12]).decode()
            with LOCK:
                UPLOADS[upload_id] = {"key": key, "parts": {}}
            return self.reply(200, "<InitiateMultipartUploadResult>"
                                   f"<Bucket>{BUCKET}</Bucket>"
                                   f"<Key>{key}</Key>"
                                   f"<UploadId>{upload_id}</UploadId>"
                                   "</InitiateMultipartUploadResult>",
                              {"Content-Type": "application/xml"})

        if "uploadId" in query:
            upload_id = query["uploadId"]
            with LOCK:
                upload = UPLOADS.pop(upload_id, None)
            if upload is None:
                return self.reply(404, "<Error><Code>NoSuchUpload</Code></Error>")
            numbers = sorted(upload["parts"])
            # Части, кроме последней, обязаны быть не меньше пяти мегабайт — так же,
            # как у настоящего S3: клиент, считающий размер части неправильно, должен
            # об этом узнать здесь, а не на живом сервере.
            for number in numbers[:-1]:
                if len(upload["parts"][number]) < 5 * 1024 * 1024:
                    return self.reply(400, "<Error><Code>EntityTooSmall</Code>"
                                           "<Message>Часть меньше пяти мегабайт</Message>"
                                           "</Error>")
            data = b"".join(upload["parts"][n] for n in numbers)
            now = datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%S.000Z")
            with LOCK:
                OBJECTS[upload["key"]] = (data, now)
            return self.reply(200, "<CompleteMultipartUploadResult>"
                                   f"<Key>{upload['key']}</Key>"
                                   "<ETag>\"done\"</ETag>"
                                   "</CompleteMultipartUploadResult>",
                              {"Content-Type": "application/xml"})
        return self.reply(400, "<Error><Code>BadRequest</Code></Error>")

    def do_DELETE(self):
        self.count()
        ok, reason = self.verify_signature(self.headers.get("x-amz-content-sha256", ""))
        if not ok:
            return self.deny(reason)
        query = self.query()
        if "uploadId" in query:
            with LOCK:
                UPLOADS.pop(query["uploadId"], None)
            return self.reply(204)
        key = self.key_from_path()
        with LOCK:
            OBJECTS.pop(key, None)
        return self.reply(204)


def seed():
    """Немного файлов и папок, чтобы в панели было на что смотреть."""
    import os
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    OBJECTS.update({
        "заметка.txt": (
            "Это учебное хранилище на вашей машине.\n"
            "Файлы живут в памяти и исчезнут, когда сервер остановят.\n".encode("utf-8"), now),
        "документы/договор.txt": ("Договор №1\n".encode("utf-8"), now),
        "документы/смета.txt": ("Смета\n".encode("utf-8"), now),
        "картинки/логотип.txt": ("Тут была бы картинка\n".encode("utf-8"), now),
        "большой файл.bin": (os.urandom(3 * 1024 * 1024), now),
    })


def main():
    global BUCKET
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if len(sys.argv) > 2:
        BUCKET = sys.argv[2]
    if "--seed" in sys.argv:
        seed()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
