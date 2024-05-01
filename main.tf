terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 3.0"
        }
        docker = {
        source = "kreuzwerker/docker"
        version = "3.0.2"
        }
    }
}
provider "aws" {
    region = "us-east-1"
    shared_credentials_file = "./credentials"
}

data "aws_ecr_authorization_token" "ecr_token" {}
provider "docker" {
    registry_auth {
        address = data.aws_ecr_authorization_token.ecr_token.proxy_endpoint
        username = data.aws_ecr_authorization_token.ecr_token.user_name
        password = data.aws_ecr_authorization_token.ecr_token.password
    }
}

locals {
    database_username = "administrator"
    database_password = "foobarbaz" # this is bad
}

resource "aws_db_instance" "taskoverflow_database" {
    allocated_storage = 20
    max_allocated_storage = 1000
    engine = "postgres"
    engine_version = "14"
    instance_class = "db.t4g.micro"
    name = "todo"
    username = local.database_username
    password = local.database_password
    parameter_group_name = "default.postgres14"
    skip_final_snapshot = true
    vpc_security_group_ids = [aws_security_group.taskoverflow_database.id]
    publicly_accessible = true

    tags = {
        Name = "taskoverflow_database"
    }
}

resource "aws_security_group" "taskoverflow_database" {
    name = "taskoverflow_database"
    description = "Allow inbound Postgresql traffic"
    ingress {
        from_port = 5432
        to_port = 5432
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }
    tags = {
        Name = "taskoverflow_database"
    }
}


data "aws_iam_role" "lab" {
    name = "LabRole"
}
data "aws_vpc" "default" {
    default = true
}
data "aws_subnets" "private" {
    filter {
        name = "vpc-id"
        values = [data.aws_vpc.default.id]
    }
}




resource "aws_ecr_repository" "taskoverflow" {
    name = "taskoverflow"
}

resource "docker_image" "taskoverflow" {
    name = "${aws_ecr_repository.taskoverflow.repository_url}:latest"
    build {
        context = "."
    }
}

resource "docker_registry_image" "taskoverflow" {
    name = docker_image.taskoverflow.name
}

resource "aws_ecs_cluster" "taskoverflow" {
    name = "taskoverflow"
}

resource "aws_ecs_task_definition" "taskoverflow" {
    family = "taskoverflow"
    network_mode = "awsvpc"
    requires_compatibilities = ["FARGATE"]
    cpu = 1024
    memory = 2048
    execution_role_arn = data.aws_iam_role.lab.arn
    container_definitions = <<DEFINITION
[
    {
        "image": "${aws_ecr_repository.taskoverflow.repository_url}",
        "cpu": 1024,
        "memory": 2048,
        "name": "todo",
        "networkMode": "awsvpc",
        "portMappings": [
            {
                "containerPort": 6400,
                "hostPort": 6400
            }
        ],
        "environment": [
            {
                "name": "SQLALCHEMY_DATABASE_URI",
                "value": "postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            },
            {
                "name": "CELERY_BROKER_URL",
                "value": "sqs://"
            },
            {
                "name": "CELERY_RESULT_BACKEND",
                "value": "db+postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            }
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/taskoverflow/todo",
                "awslogs-region": "us-east-1",
                "awslogs-stream-prefix": "ecs",
                "awslogs-create-group": "true"
            }
        }
    }
]
DEFINITION
}

resource "aws_ecs_service" "taskoverflow" {
    name = "taskoverflow"
    cluster = aws_ecs_cluster.taskoverflow.id
    task_definition = aws_ecs_task_definition.taskoverflow.arn
    desired_count = 1
    launch_type = "FARGATE"
    network_configuration {
        subnets = data.aws_subnets.private.ids
        security_groups = [aws_security_group.taskoverflow.id]
        assign_public_ip = true
    }
}

resource "aws_security_group" "taskoverflow" {
    name = "taskoverflow"
    description = "TaskOverflow Security Group"
    ingress {
        from_port = 6400
        to_port = 6400
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_ecs_task_definition" "taskworker" {
    family = "taskoverflow"
    requires_compatibilities = ["FARGATE"]
    cpu = 1024
    memory = 2048
    network_mode = "awsvpc"
    execution_role_arn = data.aws_iam_role.lab.arn
    depends_on = [aws_sqs_queue.ical_queue]
    container_definitions = <<DEFINITION
[
    {
        "image": "${aws_ecr_repository.taskworker.repository_url}",
        "cpu": 1024,
        "memory": 2048,
        "name": "worker",
        "command": ["celery", "--app", "todo.tasks.ical", "worker", "--loglevel=info"],
        "networkMode": "awsvpc",
        "environment": [
            {
                "name": "SQLALCHEMY_DATABASE_URI",
                "value": "postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            },
            {
                "name": "CELERY_BROKER_URL",
                "value": "sqs://"
            },
            {
                "name": "CELERY_RESULT_BACKEND",
                "value": "db+postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            }
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/taskoverflow/todo",
                "awslogs-region": "us-east-1",
                "awslogs-stream-prefix": "ecs",
                "awslogs-create-group": "true"
            }
        }
    }
]
DEFINITION
}

resource "aws_ecs_service" "taskworker" {
    name = "taskworker"
    cluster = aws_ecs_cluster.taskoverflow.id
    task_definition = aws_ecs_task_definition.taskworker.arn
    desired_count = 1
    launch_type = "FARGATE"
    network_configuration {
        subnets = data.aws_subnets.private.ids
        security_groups = [aws_security_group.taskworker.id]
        assign_public_ip = true
    }
}

resource "aws_security_group" "taskworker" {
    name = "taskworker"
    description = "Taskworker Security Group"
    ingress {
        from_port = 6400
        to_port = 6400
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}


resource "aws_ecr_repository" "taskworker" {
    name = "taskworker"
}

resource "docker_image" "taskworker" {
    name = "${aws_ecr_repository.taskworker.repository_url}:latest"
    build {
        context = "."
    }
}

resource "docker_registry_image" "taskworker" {
    name = docker_image.taskworker.name
}



/*

resource "aws_ecs_cluster" "taskworker" {
    name = "taskworker"
}

resource "aws_ecs_task_definition" "taskworker" {
    family = "taskworker"
    requires_compatibilities = ["FARGATE"]
    cpu = 1024
    memory = 2048
    network_mode = "awsvpc"
    execution_role_arn = data.aws_iam_role.lab.arn
    container_definitions = <<DEFINITION
[
    {
        "image": "${aws_ecr_repository.taskworker.repository_url}",
        "cpu": 1024,
        "memory": 2048,
        "name": "worker",
        "networkMode": "awsvpc",
        "environment": [
            {
                "name": "SQLALCHEMY_DATABASE_URI",
                "value": "postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            },
            {
                "name": "CELERY_BROKER_URL",
                "value": "sqs://"
            },
            {
                "name": "CELERY_RESULT_BACKEND",
                "value": "db+postgresql://${local.database_username}:${local.database_password}@${aws_db_instance.taskoverflow_database.address}:${aws_db_instance.taskoverflow_database.port}/${aws_db_instance.taskoverflow_database.name}"
            }
        ],
        "logConfiguration": {
            "logDriver": "awslogs",
            "options": {
                "awslogs-group": "/taskworker/worker",
                "awslogs-region": "us-east-1",
                "awslogs-stream-prefix": "ecs",
                "awslogs-create-group": "true"
            }
        }
    }
]
DEFINITION
}

resource "aws_ecs_service" "taskworker" {
    name = "taskworker"
    cluster = aws_ecs_cluster.taskworker.id
    task_definition = aws_ecs_task_definition.taskworker.arn
    desired_count = 1
    launch_type = "FARGATE"
    network_configuration {
        subnets = data.aws_subnets.private.ids
        security_groups = [aws_security_group.taskworker.id]
        assign_public_ip = false
    }
}

resource "aws_security_group" "taskworker" {
    name = "taskworker"
    description = "Taskworker Security Group"
    ingress {
        from_port = 6400
        to_port = 6400
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    ingress {
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}
*/