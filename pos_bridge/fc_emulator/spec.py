# -*- coding: utf-8 -*-
"""
Описание API FiscalCloud как источник правды.

Из него имитатор берёт список точек, параметры, схемы ответов и строит
«пустышку» нужной формы: объект, где присутствуют все объявленные поля со
значениями по умолчанию их типа. Поверх пустышки кладутся настоящие
значения — так ответ не может случайно потерять поле.
"""

import json
import os

SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fiscalcloud-openapi.json")


class Spec:
    def __init__(self, path=SPEC_PATH):
        with open(path, encoding="utf-8") as f:
            self.doc = json.load(f)
        self.schemas = self.doc["components"]["schemas"]

    # ── навигация ──

    @property
    def paths(self):
        return self.doc["paths"]

    def operations(self):
        """[(путь, метод, описание операции)] для всех точек."""
        for path, ops in self.doc["paths"].items():
            for method, op in ops.items():
                if method in ("get", "post", "put", "delete", "patch"):
                    yield path, method, op

    @staticmethod
    def ref_name(node):
        if not isinstance(node, dict):
            return ""
        if "$ref" in node:
            return node["$ref"].split("/")[-1]
        if "allOf" in node and node["allOf"]:
            return Spec.ref_name(node["allOf"][0])
        return ""

    def request_schema(self, op):
        body = (op.get("requestBody") or {}).get("content", {}).get("application/json", {})
        return self.ref_name(body.get("schema") or {})

    def response_schema(self, op, code="200"):
        resp = (op.get("responses") or {}).get(code, {})
        for media in ("application/json", "text/json", "text/plain"):
            node = (resp.get("content") or {}).get(media)
            if node:
                return self.ref_name(node.get("schema") or {})
        return ""

    def params(self, op):
        return op.get("parameters") or []

    # ── формы ──

    def resolve(self, node):
        """Развернуть $ref / allOf в саму схему."""
        if not isinstance(node, dict):
            return {}
        if "$ref" in node:
            return self.resolve(self.schemas.get(node["$ref"].split("/")[-1], {}))
        if "allOf" in node and node["allOf"]:
            merged = {}
            for part in node["allOf"]:
                merged.update(self.resolve(part))
            rest = {k: v for k, v in node.items() if k != "allOf"}
            merged.update(rest)
            return merged
        return node

    def blank(self, name, _depth=0):
        """Объект схемы со всеми полями и значениями по умолчанию."""
        schema = self.schemas.get(name)
        if schema is None:
            return None
        return self._blank_schema(schema, _depth)

    def _blank_schema(self, node, depth=0):
        node = self.resolve(node)
        if depth > 6:
            return None
        t = node.get("type")
        if "enum" in node and node["enum"]:
            return node["enum"][0]
        if t == "object" or "properties" in node:
            out = {}
            for key, prop in (node.get("properties") or {}).items():
                out[key] = self._blank_schema(prop, depth + 1)
            return out
        if t == "array":
            return []
        if t == "integer":
            return 0
        if t == "number":
            return 0.0
        if t == "boolean":
            return False
        if t == "string":
            return None if node.get("nullable") else ""
        return None

    def properties(self, name):
        schema = self.resolve(self.schemas.get(name, {}))
        return schema.get("properties") or {}

    # ── проверка соответствия ──

    TYPE_MAP = {
        "string": (str,),
        "integer": (int,),
        "number": (int, float),
        "boolean": (bool,),
        "array": (list,),
        "object": (dict,),
    }

    def check(self, value, name, where=""):
        """Ошибки формы ответа: недостающие поля и неверные типы."""
        schema = self.schemas.get(name)
        if schema is None:
            return ["нет схемы %s" % name]
        return self._check_schema(value, schema, where or name, 0)

    def _check_schema(self, value, node, where, depth):
        node = self.resolve(node)
        errs = []
        if depth > 6:
            return errs
        t = node.get("type")
        nullable = bool(node.get("nullable"))
        if value is None:
            # в ответах сервиса null допустим и там, где nullable не проставлен
            return errs
        if t == "object" or "properties" in node:
            if not isinstance(value, dict):
                return ["%s: ожидался объект, пришло %s" % (where, type(value).__name__)]
            for key, prop in (node.get("properties") or {}).items():
                if key not in value:
                    errs.append("%s: нет поля %s" % (where, key))
                    continue
                errs += self._check_schema(value[key], prop, "%s.%s" % (where, key), depth + 1)
            return errs
        if t == "array":
            if not isinstance(value, list):
                return ["%s: ожидался список" % where]
            for i, item in enumerate(value[:5]):
                errs += self._check_schema(item, node.get("items") or {}, "%s[%d]" % (where, i), depth + 1)
            return errs
        expect = self.TYPE_MAP.get(t)
        if expect and not isinstance(value, expect):
            if t == "number" and isinstance(value, bool):
                return ["%s: ожидалось число" % where]
            if not (t == "integer" and isinstance(value, bool) is False and isinstance(value, int)):
                errs.append("%s: ожидался %s, пришло %s" % (where, t, type(value).__name__))
        if "enum" in node and value not in node["enum"] and not (value is None and nullable):
            errs.append("%s: значение %r вне списка %s" % (where, value, node["enum"]))
        return errs


SPEC = Spec()
