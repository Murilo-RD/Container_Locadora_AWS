terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configura a região onde a infraestrutura será criada.
# 'us-east-1' é a região padrão e obrigatória para o AWS Academy.
provider "aws" {
  region = "us-east-1"
}

# --- DATA SOURCES (Fontes de Dados) ---
# O Terraform usa 'data' para buscar informações que JÁ existem na conta AWS.
# Isso evita que você precise escrever IDs manualmente (hardcoding).

# 1. Recupera o ID da conta AWS atual. Útil se precisarmos montar ARNs dinamicamente.
data "aws_caller_identity" "current" {}

# 2. Busca a VPC (Virtual Private Cloud) padrão da conta.
# O AWS Academy já vem com essa rede pronta.
data "aws_vpc" "default" {
  default = true
}

# 3. Busca todas as Subnets (sub-redes) públicas que pertencem à VPC acima.
# O Fargate precisa saber em quais subnets ele pode colocar os containers.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- SEGURANÇA ---
# Cria o "Firewall Virtual" que protege seus containers.
resource "aws_security_group" "app_sg" {
  name        = "locadora-sg-v2" 
  description = "Libera portas para Frontend, Backend e Banco"
  vpc_id      = data.aws_vpc.default.id

  # Regra de Entrada (Ingress): Libera o Frontend (React/Vite)
  # Porta 5173 é o padrão do Vite. '0.0.0.0/0' significa "qualquer IP do mundo".
  ingress {
    from_port   = 5173
    to_port     = 5173
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Regra de Entrada (Ingress): Libera o Backend (Spring Boot)
  # Necessário para o Frontend (navegador do usuário) acessar a API.
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Regra de Saída (Egress): Libera TUDO para fora.
  # Essencial para os containers baixarem as imagens do Docker Hub.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 significa todos os protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- CLUSTER ECS ---
# Cria o agrupamento lógico onde as tarefas (containers) vão rodar.
resource "aws_ecs_cluster" "main" {
  name = "cluster-locadora"
}

# --- TASK DEFINITION (Definição da Tarefa) ---
# Esta é a "receita" do bolo. Define quais containers rodar e como eles conversam.
resource "aws_ecs_task_definition" "app" {
  family                   = "tarefa-locadora"
  
  # 'awsvpc' é o modo de rede obrigatório para Fargate.
  # IMPORTANTE: Nesse modo, todos os containers compartilham o "localhost".
  network_mode             = "awsvpc"
  
  requires_compatibilities = ["FARGATE"]
  
  # Recursos totais compartilhados pelos 3 containers (1 vCPU / 3GB RAM)
  cpu                      = 1024        
  memory                   = 3072        
  
  # NOTA: Removemos 'execution_role_arn' e 'task_role_arn' para evitar erros de permissão
  # da conta AWS Academy (LabRole). Como as imagens são públicas no Docker Hub,
  # o Fargate consegue baixar sem autenticação em alguns cenários.
  
  container_definitions = jsonencode([
    # --- 1. BANCO DE DADOS (Postgres) ---
    {
      name      = "db"
      image     = "postgres:15" # Imagem oficial do Docker Hub
      essential = true
      
      # Variáveis de ambiente para configurar o usuário/senha do Postgres
      environment = [
        { name = "POSTGRES_USER", value = "postgres" },
        { name = "POSTGRES_PASSWORD", value = "postgres" },
        { name = "POSTGRES_DB", value = "Locadora" }
      ]
      portMappings = [
        { containerPort = 5432 }
      ]
      # Logs removidos para evitar erro 'AccessDenied' no CloudWatch
    },

    # --- 2. BACKEND (Spring Boot) ---
    {
      name      = "springboot"
      image     = "murilodelesposte/locadora-backend:latest"
      essential = true # Se este container morrer, a tarefa toda reinicia
      
      # Garante que o Backend só inicie depois que o container 'db' iniciar
      dependsOn = [
        { containerName = "db", condition = "START" }
      ]
      
      environment = [
        # DICA DE OURO: Como usamos network_mode 'awsvpc', o banco está em '127.0.0.1' (localhost).
        # Não usamos o nome do serviço 'db' como no Docker Compose.
        { name = "SPRING_DATASOURCE_URL", value = "jdbc:postgresql://127.0.0.1:5432/Locadora" },
        { name = "SPRING_DATASOURCE_USERNAME", value = "postgres" },
        { name = "SPRING_DATASOURCE_PASSWORD", value = "postgres" },
        { name = "SPRING_DRIVER_CLASS_NAME", value = "org.postgresql.Driver" },
        { name = "SPRING_JPA_DATABASE_PLATFORM", value = "org.hibernate.dialect.PostgreSQLDialect" },
        # 'update' faz o Hibernate criar as tabelas automaticamente
        { name = "SPRING_JPA_HIBERNATE_DDL_AUTO", value = "update" },
        
        # (Sugestão: Adicione aqui as variáveis de TIMEOUT e ERROR MESSAGE que discutimos
        # para evitar o erro 500 silencioso e problemas de inicialização lenta do banco)
      ]
      portMappings = [
        { containerPort = 8080 }
      ]
    },

    # --- 3. FRONTEND (React) ---
    {
      name      = "react"
      image     = "murilodelesposte/locadora-react:latest"
      essential = true
      dependsOn = [
        { containerName = "springboot", condition = "START" }
      ]
      portMappings = [
        { containerPort = 5173 }
      ]
    }
  ])
}

# --- SERVICE (Serviço) ---
# O Service é o "gerente". Ele garante que a Task Definition esteja sempre rodando.
resource "aws_ecs_service" "app_service" {
  name            = "servico-locadora"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1       # Quantas cópias queremos (apenas 1 para economizar)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids   # Usa as subnets descobertas lá em cima
    security_groups  = [aws_security_group.app_sg.id] # Aplica o Firewall
    assign_public_ip = true # OBRIGATÓRIO: Sem isso, o Fargate não tem internet para baixar o Docker
  }
}

# --- OUTPUTS ---
# Imprime uma mensagem no final do 'terraform apply' para ajudar a localizar a aplicação.
output "instrucoes" {
  value = "Acesse o Console AWS -> ECS -> Clusters -> Tasks -> Clique na Task -> Pegue o IP Publico. Acesse http://IP:5173"
}