pack:
	packer build -var "do_token=$$(cat ../env.tfvars | grep do_token | cut -d "\"" -f2)" image.json
