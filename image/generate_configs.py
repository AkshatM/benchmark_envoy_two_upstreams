import itertools
from jinja2 import Environment, FileSystemLoader

def render_yaml(settings, filename):
    environment = Environment(loader=FileSystemLoader('configs'))
    template = environment.get_template('envoy-template.yaml.j2')
    with open('configs/{}'.format(filename), "w") as envoy_yaml:
        envoy_yaml.write(template.render(settings=settings))

setting_names = [
    'add_user_agent', 
    'server_name', 
    'cluster', 
    'forward_client_cert_details', 
    'set_current_client_cert_details', 
    'use_remote_address', 
    'skip_xff_append'
]

def generate_settings(config_type):

    settings = {}

    for index, setting in enumerate(setting_names):
        if config_type[index] == "1":
            settings[setting] = True

    return settings

with open("envoy_configs", "r") as envoy_config_types_file:

    config_types = envoy_config_types_file.readlines()

    for config_type in config_types:
        configs = config_type.strip()
        settings = generate_settings(configs)
        filename = "envoy-{}.yaml".format(configs)
        render_yaml(settings, filename)
