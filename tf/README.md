
# default us-east-2
terraform plan
terraform apply
terraform destroy

terraform plan -var 'aws_region=us-east-1'
terraform apply -var 'aws_region=us-east-1' -var 'key_name=ecs'
terraform destroy -var 'aws_region=us-east-1'

