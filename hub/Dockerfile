# The station display hub (owner's note N46): one small image, run on the station's mini PC or a virtual machine.
FROM python:3.12-slim@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 MASSLAK_HUB_STATE=/var/lib/masslak-hub
WORKDIR /opt/hub
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --system --uid 10001 hub \
 && mkdir -p /var/lib/masslak-hub && chown hub /var/lib/masslak-hub
COPY masslak_hub ./masslak_hub
USER hub
# the hub reads /proc/net/arp to know each player's hardware address: run it on the host's network (network_mode: host)
EXPOSE 8080
ENTRYPOINT ["python", "-m", "masslak_hub"]
CMD ["serve", "--port", "8080"]
