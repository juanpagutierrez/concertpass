#!/usr/bin/env bash
# Crea RDS PostgreSQL dentro de la VPC del cluster (privada, accesible solo desde la VPC)
# y guarda las credenciales en AWS Secrets Manager. Requiere que el cluster ya exista.
source "$(dirname "$0")/config.sh"
require_cmd aws jq

cluster_exists || die "Primero crea el cluster (create-cluster.sh): RDS se crea en su VPC"

vpc_id=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)
vpc_cidr=$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --query 'Vpcs[0].CidrBlock' --output text)
ok "VPC del cluster: $vpc_id ($vpc_cidr)"

log "DB subnet group (subnets privadas del cluster)"
subnets=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].SubnetId' --output text)
if [[ -z "$subnets" ]]; then
  subnets=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
fi
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  ok "$DB_SUBNET_GROUP ya existe"
else
  # shellcheck disable=SC2086
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "Concertpass RDS subnets" --subnet-ids $subnets >/dev/null
  ok "$DB_SUBNET_GROUP creado"
fi

log "Security group de RDS (5432 abierto solo a la VPC)"
sg_id=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$DB_SECURITY_GROUP" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ "$sg_id" == "None" || -z "$sg_id" ]]; then
  sg_id=$(aws ec2 create-security-group --group-name "$DB_SECURITY_GROUP" \
    --description "Concertpass RDS PostgreSQL" --vpc-id "$vpc_id" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --protocol tcp --port 5432 --cidr "$vpc_cidr" >/dev/null
fi
ok "$sg_id"

log "Credenciales en Secrets Manager ($SECRET_NAME)"
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  password=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
    --query SecretString --output text | jq -r .password)
  ok "El secreto ya existe, se reutiliza el password"
else
  password=$(aws secretsmanager get-random-password --password-length 32 \
    --exclude-punctuation --query RandomPassword --output text)
  aws secretsmanager create-secret --name "$SECRET_NAME" \
    --description "Credenciales de RDS PostgreSQL para Concertpass" \
    --secret-string "$(jq -cn --arg u "$DB_USER" --arg p "$password" '{username:$u,password:$p}')" >/dev/null
  ok "Secreto creado"
fi

log "Instancia RDS PostgreSQL $DB_INSTANCE_ID"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  ok "La instancia ya existe"
else
  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --engine postgres \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --allocated-storage 20 \
    --storage-type gp3 \
    --db-name "$DB_NAME" \
    --master-username "$DB_USER" \
    --master-user-password "$password" \
    --vpc-security-group-ids "$sg_id" \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --no-publicly-accessible \
    --no-multi-az \
    --backup-retention-period 0 \
    --no-deletion-protection >/dev/null
  ok "Creación iniciada"
fi

log "Esperando a que RDS esté disponible (tarda ~5-10 min)"
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
read -r host port < <(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port]' --output text)
ok "Endpoint: $host:$port"

# El secreto queda con todo lo necesario para conectarse (mismo formato que usa RDS).
aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "$(jq -cn \
  --arg u "$DB_USER" --arg p "$password" --arg h "$host" --arg port "$port" --arg db "$DB_NAME" \
  '{engine:"postgres",username:$u,password:$p,host:$h,port:($port|tonumber),dbname:$db}')" >/dev/null
ok "Secreto actualizado con host, puerto y base de datos"
