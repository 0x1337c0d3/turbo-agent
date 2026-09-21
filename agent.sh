swift build -c release --product TurboAgent
bash Scripts/package-agent.sh release
.build/release/TurboAgent.app/Contents/MacOS/TurboAgent --yolo
