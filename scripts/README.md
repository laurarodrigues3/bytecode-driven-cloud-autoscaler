# Scripts de provisionamento AWS — Nature@Cloud

Scripts **bash** (`.sh`) que automatizam todo o ciclo de vida da infra AWS
do projecto. Correm em Linux, macOS, ou Windows (WSL).

---

## Pré-requisitos

1. **AWS CLI v2** → `aws --version`
2. **Credenciais configuradas** → `aws configure` (IAM user)
3. **bash + curl + ssh + scp**
4. **Java 11 + Maven** para `mvn package` antes da AMI

Validar:
```bash
aws sts get-caller-identity
```

### ⚠️ WSL (Windows)

Em WSL, `chmod` **não funciona** em paths `/mnt/c/...` (Windows FS).
A key pair é guardada em `~/.ssh/cnv-keypair.pem` (Linux FS).
Ver `aws-config.sh:41`.

---

## Pipeline completa (~12 minutos)

```bash
cd scripts

# 0. (Opcional) Apagar tudo de sessões anteriores
echo "YES" | ./99-cleanup.sh --deep

# 1. IAM: 3 Roles + 2 Instance Profiles
./01-setup-iam.sh

# 2. Network: key pair + 2 Security Groups (worker + LB)
./02-setup-network.sh

# 3. Build dos JARs (na raiz do projecto)
cd .. && mvn clean package -DskipTests && cd scripts

# 4. AMI (~5 min): worker image com Java 11 + JARs + systemd
./03-create-ami.sh

# 5. Lançar worker
./04-launch-worker.sh

# 6. Lançar Load Balancer
./05-launch-lb.sh $(cat .state/worker-instance-ids.txt)
```

A tabela DynamoDB é criada automaticamente pelo `MetricsStorageService`
no primeiro pedido.

---

## Sessão de trabalho (código não mudou)

```bash
cd scripts
./04-launch-worker.sh
./05-launch-lb.sh $(cat .state/worker-instance-ids.txt)
# ... testes ...
./99-cleanup.sh
```

Se o código mudou, recriar a AMI primeiro:
```bash
cd .. && mvn clean package -DskipTests && cd scripts
./03-create-ami.sh
```

---

## Cleanup

```bash
./99-cleanup.sh              # Só EC2s (preserva AMI, SGs, IAM)
echo "YES" | ./99-cleanup.sh --deep   # TUDO
```

---

## Scripts de teste (`test/`)

| Script | Descrição |
|---|---|
| `_benchmark-icount.sh` | Mede instruction count localmente |
| `_benchmark-dna.sh` | Mede DNA localmente |
| `_check-state.sh` | Estado dos recursos AWS |
| `_collect-logs.sh` | Recolhe logs dos workers e LB |
| `_diagnose-orphans.sh` | Recursos órfãos do projecto |

---

## Ficheiros gerados (.gitignore)

| Ficheiro | Descrição |
|---|---|
| `~/.ssh/cnv-keypair.pem` | Chave SSH privada (Linux FS, 400) |
| `.state/worker-ami-id.txt` | AMI ID |
| `.state/worker-sg-id.txt` | SG worker |
| `.state/lb-sg-id.txt` | SG LB |
| `.state/worker-instance-ids.txt` | Worker IDs |
| `.state/lb-instance-id.txt` | LB ID |

---

## Configuração (`aws-config.sh`)

Para mudar de região:
```bash
export AWS_REGION=us-east-1
aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
    --query "sort_by(Images,&CreationDate)[-1].ImageId" \
    --output text --region us-east-1
```

---

## Validação

| # | Comando | Prova |
|---|---|---|
| 1 | `aws sts get-caller-identity` | Credenciais |
| 2 | `aws ec2 describe-regions` | Permissões EC2 |
| 3 | Programa Java de teste | SDK Java |
| 4 | `aws dynamodb list-tables` | DynamoDB |
| 5 | `./04-launch-worker.sh` + `curl` | EC2 + SG + key |
| 6 | `aws sts get-caller-identity` dentro EC2 | Instance Profile |
| 7 | LB + worker + `aws dynamodb scan` | End-to-end |
