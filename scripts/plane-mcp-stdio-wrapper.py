#!/usr/bin/env python3
"""Run Plane MCP stdio with a smaller Codex-compatible default tool set."""

from __future__ import annotations

import os
import sys

from plane_mcp import server
from plane_mcp.__main__ import main
from plane_mcp.tools.cycles import register_cycle_tools
from plane_mcp.tools.epics import register_epic_tools
from plane_mcp.tools.initiatives import register_initiative_tools
from plane_mcp.tools.intake import register_intake_tools
from plane_mcp.tools.labels import register_label_tools
from plane_mcp.tools.milestones import register_milestone_tools
from plane_mcp.tools.modules import register_module_tools
from plane_mcp.tools.pages import register_page_tools
from plane_mcp.tools.projects import register_project_tools
from plane_mcp.tools.states import register_state_tools
from plane_mcp.tools.users import register_user_tools
from plane_mcp.tools.work_item_activities import register_work_item_activity_tools
from plane_mcp.tools.work_item_comments import register_work_item_comment_tools
from plane_mcp.tools.work_item_links import register_work_item_link_tools
from plane_mcp.tools.work_item_properties import register_work_item_property_tools
from plane_mcp.tools.work_item_relations import register_work_item_relation_tools
from plane_mcp.tools.work_item_types import register_work_item_type_tools
from plane_mcp.tools.work_items import register_work_item_tools
from plane_mcp.tools.work_logs import register_work_log_tools
from plane_mcp.tools.workspaces import register_workspace_tools


REGISTRARS = {
    "cycles": register_cycle_tools,
    "epics": register_epic_tools,
    "initiatives": register_initiative_tools,
    "intake": register_intake_tools,
    "labels": register_label_tools,
    "milestones": register_milestone_tools,
    "modules": register_module_tools,
    "pages": register_page_tools,
    "projects": register_project_tools,
    "states": register_state_tools,
    "users": register_user_tools,
    "work_item_activities": register_work_item_activity_tools,
    "work_item_comments": register_work_item_comment_tools,
    "work_item_links": register_work_item_link_tools,
    "work_item_properties": register_work_item_property_tools,
    "work_item_relations": register_work_item_relation_tools,
    "work_item_types": register_work_item_type_tools,
    "work_items": register_work_item_tools,
    "work_logs": register_work_log_tools,
    "workspaces": register_workspace_tools,
}

DEFAULT_GROUPS = "work_items,work_item_comments,states"


def register_selected_tools(mcp):
    groups = os.getenv("PLANE_MCP_TOOL_GROUPS", DEFAULT_GROUPS)
    selected = [group.strip() for group in groups.split(",") if group.strip()]
    unknown = sorted(set(selected) - set(REGISTRARS))
    if unknown:
        known = ", ".join(sorted(REGISTRARS))
        raise ValueError(f"Unknown PLANE_MCP_TOOL_GROUPS entries: {unknown}. Known groups: {known}")
    for group in selected:
        REGISTRARS[group](mcp)


server.register_tools = register_selected_tools

if len(sys.argv) == 1:
    sys.argv.append("stdio")

main()
