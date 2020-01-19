variable "do_token" {
	description = "Your DigitalOcean API token. Get this from the DigitalOcean website."
}

variable "user_ssh_key_name" {
	description = "Registered name of the SSH key attached to your Digitalocean account."
}

provider "digitalocean" {
	token = "${var.do_token}"
}

data "digitalocean_ssh_key" "user" {
        name = "${var.user_ssh_key_name}"
}

data "digitalocean_droplet_snapshot" "benchmark_machine" {
  name_regex  = "^benchmark_image"
  region      = "blr1"
  most_recent = true
}

resource "digitalocean_droplet" "benchmark_machine" {
	# this image is built in the /image folder
	image  = "${data.digitalocean_droplet_snapshot.benchmark_machine.id}"
	name   = "benchmark-instance-1"
	region = "blr1"
	size   = "s-8vcpu-32gb"
        ssh_keys = ["${data.digitalocean_ssh_key.user.id}"]
        user_data = "${file("run_perf_test.sh")}"
}
