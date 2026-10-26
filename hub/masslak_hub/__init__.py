"""Masslak station display hub (owner's note N46, docs/design/STATION_DISPLAYS_LAN.md).

One small server inside a station: the only thing that talks to the platform, outbound only, and the only server the
screens' players reach on the station's own network. It keeps the boards of its screens, serves each to the one player
approved for it, keeps showing them when the internet is cut, and reports the players it sees.
"""
VERSION = "1.0.0"
