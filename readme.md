Welcome to `syrc`, a CLI tool to
- Sync a local folder with a remote folder, potentially on a different machine
- Run a command
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

# Namespaces
- crypto
	- Secret
		- Sedes from file
	- Sign with HMAC-SHA256: HMAC(Secret, Time+Message)
	- Hash
- cli
	- Args
- cfg
	- Config
		- name, server, port
- mdl
	- Tree
- store
	- Object/File
	- Copy file parts efficiently: https://cfengine.com/blog/2024/efficient-data-copying-on-modern-linux/
- brkr
	- Broker
- clnt
	- Client
- srvr
	- Server
- net
- msg
	- Message
		- version, id
		- read(), write()
		- Type(u16), Size(u48), Data(zon, string)
- rubr
	- Support for collecting func from rubr automatically in a single file
- app
- main
	- `supr -C ./ -s abc cmd args`
