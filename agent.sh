swift build -c release --product TurboFieldfareAgent
bash Scripts/package-agent.sh release
.build/release/TurboFieldfareAgent.app/Contents/MacOS/TurboFieldfareAgent --yolo
