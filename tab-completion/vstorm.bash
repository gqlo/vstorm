# Bash tab completion for vstorm
# Source this file to enable: source tab-completion/vstorm.bash
# Or add to .bashrc: source /path/to/vstorm/tab-completion/vstorm.bash

_vstorm() {
	local cur=${COMP_WORDS[COMP_CWORD]}
	local opts=(
		-n -q -y -h
		--help
		--datasource= --dv-url= --storage-size= --storage-class=
		--access-mode=
		--snapshot-class= --no-snapshot
		--pvc-base-name= --batch-id= --basename=
		--cores= --memory= --request-memory= --request-cpu=
		--vms= --vms-per-namespace= --namespaces=
		--run-strategy=
		--create-existing-vm --wait --wait= --run-strategy=
		--containerdisk --containerdisk=
		--cloudinit= --custom-templates=
		--profile --profile=
		--delete= --delete-all --yes
	)

	# Complete option names when current word starts with - or --
	if [[ "$cur" == -* ]]; then
		COMPREPLY=( $(compgen -W "${opts[*]}" -- "$cur") )
	fi
}

complete -F _vstorm vstorm
