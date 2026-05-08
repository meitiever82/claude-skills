#!/usr/bin/env python3
"""launch_xml_to_py.py — Stub-translate a ROS1 .launch (XML) into a ROS2 .launch.py.

Usage:
    python3 launch_xml_to_py.py path/to/foo.launch [> foo.launch.py]

Handles common patterns:
    <arg name="x" default="..."/>             -> DeclareLaunchArgument
    <param name="..." value="..."/>           -> in-line dict to parameters=[...]
    <rosparam command="load" file="..."/>     -> file path passed to parameters=[...]
    <node pkg="..." type="..." name="..."     -> Node(package=..., executable=..., name=...)
          if="$(arg x)" output="screen">
    <remap from="..." to="..."/>              -> remappings=[(from, to)]
    <include file="$(find pkg)/foo.launch"/>  -> IncludeLaunchDescription stub

Does NOT translate:
    - <machine>, <env>, complex <test> nodes
    - $(eval ...) expressions  (left as TODO)
    - ROS1's special "$(arg x)" inside arbitrary text  (uses LaunchConfiguration)
The output is a STARTING POINT — review and edit.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET


def py_str(s: str) -> str:
    """Escape a string for Python single-quoted literal."""
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def subst(value: str) -> str:
    """Translate $(arg X), $(find pkg) into LaunchConfiguration / FindPackageShare.

    Returns either a quoted string or a Python expression involving substitutions.
    """
    # Trivial case: no substitution
    if "$(" not in value:
        return py_str(value)

    parts: list[str] = []
    i = 0
    while i < len(value):
        if value[i:i + 2] == "$(":
            depth = 1
            j = i + 2
            while j < len(value) and depth:
                if value[j:j + 2] == "$(":
                    depth += 1
                    j += 2
                elif value[j] == ")":
                    depth -= 1
                    j += 1
                else:
                    j += 1
            inner = value[i + 2:j - 1]
            tokens = inner.split(maxsplit=1)
            kind = tokens[0]
            arg = tokens[1] if len(tokens) > 1 else ""
            if kind == "arg":
                parts.append(f"LaunchConfiguration({py_str(arg)})")
            elif kind == "find":
                parts.append(f"FindPackageShare({py_str(arg)})")
            elif kind == "eval":
                parts.append(f"# TODO eval: {arg}")
            else:
                parts.append(py_str(value[i:j]))
            i = j
        else:
            k = value.find("$(", i)
            if k == -1:
                parts.append(py_str(value[i:]))
                i = len(value)
            else:
                parts.append(py_str(value[i:k]))
                i = k

    if len(parts) == 1:
        return parts[0]
    # PathJoinSubstitution if it looks like a path made of FindPackageShare + str
    if any("FindPackageShare" in p for p in parts):
        joined = ", ".join(parts).replace("'/'", "")
        return f"PathJoinSubstitution([{joined}])"
    return "[" + ", ".join(parts) + "]"


def cond_for(elem: ET.Element) -> str | None:
    """Return 'IfCondition(...)' or 'UnlessCondition(...)' if the element has if/unless."""
    if "if" in elem.attrib:
        return f"IfCondition({subst(elem.attrib['if'])})"
    if "unless" in elem.attrib:
        return f"UnlessCondition({subst(elem.attrib['unless'])})"
    return None


def translate_node(node: ET.Element) -> list[str]:
    pkg = node.attrib.get("pkg", "TODO")
    typ = node.attrib.get("type", node.attrib.get("exec", "TODO"))
    name = node.attrib.get("name", typ)
    output = node.attrib.get("output", "screen")

    params: list[str] = []
    remaps: list[str] = []
    for child in node:
        if child.tag == "param":
            n = child.attrib["name"]
            if "value" in child.attrib:
                v = child.attrib["value"]
                # Try to coerce to int/float/bool
                try:
                    pyv = repr(int(v))
                except ValueError:
                    try:
                        pyv = repr(float(v))
                    except ValueError:
                        if v.lower() == "true":
                            pyv = "True"
                        elif v.lower() == "false":
                            pyv = "False"
                        else:
                            pyv = py_str(v)
                params.append(f"{{{py_str(n)}: {pyv}}}")
        elif child.tag == "rosparam" and child.attrib.get("command") == "load":
            f = child.attrib.get("file", "")
            params.append(subst(f))
        elif child.tag == "remap":
            params  # no-op
            remaps.append(f"({subst(child.attrib['from'])}, {subst(child.attrib['to'])})")

    lines = [
        "Node(",
        f"    package={py_str(pkg)},",
        f"    executable={py_str(typ)},",
        f"    name={py_str(name)},",
        f"    output={py_str(output)},",
    ]
    if params:
        lines.append(f"    parameters=[{', '.join(params)}],")
    if remaps:
        lines.append(f"    remappings=[{', '.join(remaps)}],")
    c = cond_for(node)
    if c:
        lines.append(f"    condition={c},")
    lines.append("),")
    return lines


def walk(elem: ET.Element, declared: list[str], actions: list[str],
         pending_node_params: list[str], parent_cond: str | None = None) -> None:
    """Walk a launch XML tree, descending into <group>.

    `pending_node_params` accumulates top-level <rosparam command="load"> and
    <param> nodes that should be folded into the next emitted <node>.
    `parent_cond` is the IfCondition/UnlessCondition inherited from a parent
    <group> wrapper; it is OR-merged into each child node's condition.
    """
    for child in elem:
        if child.tag == "arg":
            n = child.attrib["name"]
            d = child.attrib.get("default", child.attrib.get("value", ""))
            declared.append(
                f"DeclareLaunchArgument({py_str(n)}, default_value={py_str(d)}),"
            )
        elif child.tag == "node":
            lines = translate_node(child)
            # Inject inherited <group> condition if the node has none of its own.
            if parent_cond and not any("condition=" in ln for ln in lines):
                lines.insert(-1, f"    condition={parent_cond},")
            # Top-level <rosparam>/<param> attach only to the FIRST emitted node.
            if pending_node_params and not any("parameters=" in ln for ln in lines):
                lines.insert(-1, f"    parameters=[{', '.join(pending_node_params)}],")
                pending_node_params.clear()
            actions.extend(lines)
        elif child.tag == "group":
            # Take the group's if/unless and propagate to children.
            child_cond = cond_for(child) or parent_cond
            walk(child, declared, actions, pending_node_params, child_cond)
        elif child.tag == "include":
            f = child.attrib.get("file", "")
            actions.append(
                f"IncludeLaunchDescription(PythonLaunchDescriptionSource({subst(f)})),"
            )
        elif child.tag == "rosparam" and child.attrib.get("command") == "load":
            # Defer onto pending_node_params; will attach to next <node>.
            pending_node_params.append(subst(child.attrib.get("file", "")))
        elif child.tag == "param":
            n = child.attrib.get("name", "")
            v = child.attrib.get("value", "")
            pending_node_params.append(f"{{{py_str(n)}: {subst(v)}}}")
        # Other tags (env, machine, test, …) silently ignored.


def translate(launch_xml_path: str) -> str:
    tree = ET.parse(launch_xml_path)
    root = tree.getroot()
    if root.tag != "launch":
        raise SystemExit(f"not a <launch> file: {launch_xml_path}")

    declared: list[str] = []
    actions: list[str] = []
    pending_node_params: list[str] = []
    walk(root, declared, actions, pending_node_params, parent_cond=None)

    body = "\n        ".join(declared + actions)
    return f"""# Generated by launch_xml_to_py.py from {launch_xml_path}
# Review and edit — this is a starting point, not a final translation.
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition, UnlessCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():
    return LaunchDescription([
        {body}
    ])
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="ROS1 .launch (XML) file")
    args = ap.parse_args()
    sys.stdout.write(translate(args.path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
