
data "aws_availability_zones" "available" {}

variable "environ" {default = "UNKNOWN" }
variable "appname" {default = "HelloGoEcsTerraform" }
variable "host_port" { default = 8080 }
variable "docker_port" { default = 8080 }
variable "lb_port" { default = 80 }
variable "master_port" {
  description = "The port the master will use for redis requests"
  #default = 6379
  default = 8080
}

variable "aws_region" { default = "us-east-2" }
variable "key_name" {default = "dev"}
variable "dockerimg" {default = "mllu/hello-go-ecs-terraform"}
variable "instance_type" {
  default = "t2.micro"
}

variable "min_scale_size" {default = "0" }
variable "max_scale_size" {default = "10" }

provider "aws" {
  region = "${var.aws_region}"
}

/* ECS optimized AMIs per region */
variable "amis" {
  default = {
    us-east-1 = "ami-04351e12"
    us-east-2 = "ami-207b5a45"
    us-west-1 = "ami-7d664a1d"
    us-west-2 = "ami-57d9cd2e"
    ca-central-1 = "ami-3da81759"
  }
}

resource "aws_vpc" "main" {
  cidr_block = "10.10.0.0/16"
  enable_dns_hostnames = "true"
}

resource "aws_subnet" "main" {
  count             = "${length(data.aws_availability_zones.available.names)}"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id            = "${aws_vpc.main.id}"
  map_public_ip_on_launch = "true"
}


resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"
}

resource "aws_route_table" "r" {
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
}

resource "aws_route_table_association" "a" {
  count             = "${length(data.aws_availability_zones.available.names)}"
  subnet_id      = "${element(aws_subnet.main.*.id, count.index)}"
  route_table_id = "${aws_route_table.r.id}"
}

resource "aws_security_group" "allow_all_outbound" {
  name_prefix = "${var.appname}-${var.environ}-${aws_vpc.main.id}-"
  description = "Allow all outbound traffic"
  vpc_id = "${aws_vpc.main.id}"

  egress = {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_all_inbound" {
  name_prefix = "${var.appname}-${var.environ}-${aws_vpc.main.id}-"
  description = "Allow all inbound traffic"
  vpc_id = "${aws_vpc.main.id}"

  ingress = {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "allow_cluster" {
  name_prefix = "${var.appname}-${var.environ}-${aws_vpc.main.id}-"
  description = "Allow all traffic within cluster"
  vpc_id = "${aws_vpc.main.id}"

  ingress = {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    self = true
  }

  egress = {
    from_port = 0
    to_port = 65535
    protocol = "tcp"
    self = true
  }
}

resource "aws_security_group" "allow_all_ssh" {
  name_prefix = "${var.appname}-${var.environ}-${aws_vpc.main.id}-"
  description = "Allow all inbound SSH traffic"
  vpc_id = "${aws_vpc.main.id}"

  ingress = {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# set up master node
resource "aws_eip" "master_ip" {
  vpc = true
  instance   = "${aws_instance.master.id}"
  # reduntant explicit dependency just to be clear
  depends_on = ["aws_instance.master"]
}

resource "aws_security_group" "master" {
  name = "master"
  vpc_id = "${aws_vpc.main.id}"

  ingress {
    from_port = "${var.master_port}"
    to_port = "${var.master_port}"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = "22"
    to_port = "22"
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "master" {
  ami = "${lookup(var.amis, var.aws_region)}"
  instance_type = "${var.instance_type}"
  key_name = "${var.key_name}"
  subnet_id = "${element(aws_subnet.main.*.id, 1)}"
  vpc_security_group_ids = ["${aws_security_group.master.id}"]

  tags {
    Name = "master"
  }

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup busybox httpd -f -p "${var.master_port}" &
              EOF
}

# end of setting master

# This role has a trust relationship which allows
# to assume the role of ec2
resource "aws_iam_role" "ecs" {
  name = "${var.appname}_ecs_${var.environ}"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
      }
    ]
  }
  EOF
}

# This is a policy attachement for the "ecs" role, it provides access
# to the the ECS service.
resource "aws_iam_policy_attachment" "ecs_for_ec2" {
  name = "${var.appname}_${var.environ}"
  roles = ["${aws_iam_role.ecs.id}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# This is the role for the load balancer to have access to ECS.
resource "aws_iam_role" "ecs_elb" {
  name = "${var.appname}_ecs_elb_${var.environ}"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "",
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }
  EOF
}

# Attachment for the above IAM role.
resource "aws_iam_policy_attachment" "ecs_elb" {
  name = "${var.appname}_ecs_elb_${var.environ}"
  roles = ["${aws_iam_role.ecs_elb.id}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole"
}

# The ECS cluster
resource "aws_ecs_cluster" "cluster" {
    name = "${var.appname}_${var.environ}"
}

data "template_file" "task_definition" {
  #depends_on = ["null_resource.docker"]
  template = "${file("task-definition.json.tmpl")}"
  vars {
    name = "${var.appname}_${var.environ}"
    image = "${var.dockerimg}"
    docker_port = "${var.docker_port}"
    host_port = "${var.host_port}"
    # this is so that task is always deployed when the image changes
    #_img_id = "${null_resource.docker.id}"
  }
}

resource "aws_ecs_task_definition" "ecs_task" {
  family = "${var.appname}_${var.environ}"
  container_definitions = "${data.template_file.task_definition.rendered}"
}

resource "aws_elb" "service_elb" {
  name = "${var.appname}-${var.environ}"
  subnets  = ["${aws_subnet.main.*.id}"]
  connection_draining = true
  cross_zone_load_balancing = true
  security_groups = [
    "${aws_security_group.allow_cluster.id}",
    "${aws_security_group.allow_all_inbound.id}",
    "${aws_security_group.allow_all_outbound.id}"
  ]

  listener {
    instance_port = "${var.host_port}"
    instance_protocol = "http"
    lb_port = "${var.lb_port}"
    lb_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 10
    target = "HTTP:${var.host_port}/"
    interval = 5
    timeout = 4
  }
}

resource "aws_ecs_service" "ecs_service" {
  name = "${var.appname}_${var.environ}"
  cluster = "${aws_ecs_cluster.cluster.id}"
  task_definition = "${aws_ecs_task_definition.ecs_task.arn}"
  desired_count = "${length(data.aws_availability_zones.available.names)}"
  iam_role = "${aws_iam_role.ecs_elb.arn}"
  depends_on = ["aws_iam_policy_attachment.ecs_elb"]
  deployment_minimum_healthy_percent = 50

  load_balancer {
    elb_name = "${aws_elb.service_elb.id}"
    container_name = "${var.appname}_${var.environ}"
    container_port = "${var.docker_port}"
  }
}

resource "aws_iam_instance_profile" "ecs" {
  name = "${var.appname}_${var.environ}"
  role = "${aws_iam_role.ecs.name}"
}

resource "aws_launch_configuration" "ecs_cluster" {
  name = "${var.appname}_cluster_conf_${var.environ}"
  instance_type = "${var.instance_type}"
  image_id = "${lookup(var.amis, var.aws_region)}"
  iam_instance_profile = "${aws_iam_instance_profile.ecs.id}"
  associate_public_ip_address = true
  security_groups = [
    "${aws_security_group.allow_all_ssh.id}",
    "${aws_security_group.allow_all_outbound.id}",
    "${aws_security_group.allow_cluster.id}",
  ]
  user_data = "#!/bin/bash\necho ECS_CLUSTER='${var.appname}_${var.environ}' > /etc/ecs/ecs.config"
  key_name = "${var.key_name}"
}

resource "aws_autoscaling_group" "ecs_cluster" {
  name = "${var.appname}_${var.environ}"
  vpc_zone_identifier  = ["${aws_subnet.main.*.id}"]
  min_size = "${var.min_scale_size}"
  max_size = "${var.max_scale_size}"
  desired_capacity = "${length(data.aws_availability_zones.available.names)}"
  launch_configuration = "${aws_launch_configuration.ecs_cluster.name}"
  health_check_type = "EC2"
}

#resource "null_resource" "docker" {
#  triggers {
#    # This is a lame hack but it works
#    log_hash = "${base64sha256(file("${path.module}/../.git/logs/HEAD"))}"
#  }
#  provisioner "local-exec" {
#    command = "cd .. && docker build -t ${var.dockerimg} . && docker push ${var.dockerimg}"
#  }
#}

output "master_public_dns" {
  value = "${aws_instance.master.public_dns}"
}

output "master_public_ip" {
  value = "${aws_instance.master.public_ip}"
}

output "availability_zones" {
  value = "${data.aws_availability_zones.available.names}"
}

output "elb_dns_name" {
  value = "${aws_elb.service_elb.dns_name}"
}

