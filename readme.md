Welcome to `syrc`, a CLI tool to
- Sync a local folder with a remote folder, potentially on a different machine
- Run a command on that remote folder
- Collect the output from the command and newly created files

# Modes
- Server
- Broker
- Client

# Requirements
- Must support setting custom env vars
- Must run command in same folder
- Must collect newly created files back
	- Difficult todo with rsync
- Must support Windows
	- Difficult todo with rsync
- Must manage a set of folders where a build can take place
