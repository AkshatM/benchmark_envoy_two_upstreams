develop:
	pip install -r requirements.txt

build:
	sudo terraform apply -auto-approve -var-file="env.tfvars"

watch:
	sudo ssh -o StrictHostKeychecking=no root@$$(sudo terraform show | grep ipv4_address | cut -d "\"" -f 2) 'tail -f /var/log/cloud-init-output.log'

destroy:
	sudo terraform destroy -auto-approve -var-file="env.tfvars"

connect:
	sudo ssh -o StrictHostKeychecking=no root@$$(sudo terraform show | grep ipv4_address | cut -d "\"" -f 2)
