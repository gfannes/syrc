&!:syrc

Welcome to `syrc`, a CLI tool to
- Sync a local folder with a remote folder, potentially on a different machine
- Run a command
- Collect the output from the command and newly created files

# Modes
- Server
- Broker
- Client

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
