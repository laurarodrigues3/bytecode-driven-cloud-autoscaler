# Cenas para ter abertas antes de gravar:
# 1. Browser → AWS Console → EC2 → Instances (filtrar por tag Project=NatureAtCloud)
# 2. Browser → AWS Console → DynamoDB → Tables → cnv-metrics → Explore items
# 3. Terminal WSL principal — é aqui que vais correr os comandos
# 4. Terminal WSL secundário — para abrires SSH para os workers (top)
# 5. VS Code com o projeto (opcional, só para mostrar o código)







# PARTE 0: SETUP 
# Mostrar os JARs locais (datas e hashes)

ls -la loadbalancer/target/loadbalancer-*-jar-with-dependencies.jar
ls -la webserver/target/webserver-*-jar-with-dependencies.jar
ls -la javassist/target/javassist-agent-*-jar-with-dependencies.jar

md5sum loadbalancer/target/loadbalancer-*-jar-with-dependencies.jar
md5sum webserver/target/webserver-*-jar-with-dependencies.jar
md5sum javassist/target/javassist-agent-*-jar-with-dependencies.jar

# AWS Console mostrar worker e LB a correr
# worker e LB - UP

# SSH para o worker: mostrar que os ficheiros vieram da AMI
ssh -i ~/.ssh/cnv-keypair.pem ec2-user@52.16.206.151 'ls -la /opt/cnv/'

# Hash do JAR no LB 
echo "  Hash do JAR no LB  "
ssh -i ~/.ssh/cnv-keypair.pem ec2-user@54.247.202.116 'md5sum /opt/cnv/loadbalancer.jar'










# PARTE 1: BASIC REQUESTS


# Mostrar worker no AWS Console
# 3 pedidos DIRETOS ao worker (tamanho XS/S)

curl -s -o fractal_worker.png "http://52.16.206.151:8000/fractals?w=800&h=600&iterations=100"
curl -s "http://52.16.206.151:8000/grayscott?size=128&maxIterations=500&f=0.030&k=0.062&stopOnExtinction=false&seedMode=center"
curl -s "http://52.16.206.151:8000/dna?seq1=seq1:ATGCATGCATGC&seq2=seq2:ATGCATGCATGC&minLength=3&stopOnFirst=false"




# Mostrar LB no AWS Console
# Os mesmos 3 pedidos, mas agora VIA LB

curl -s -o fractal_lb.png "http://54.247.202.116:8080/fractals?w=800&h=600&iterations=100"
curl -s "http://54.247.202.116:8080/grayscott?size=128&maxIterations=500&f=0.030&k=0.062&stopOnExtinction=false&seedMode=center"
curl -s "http://54.247.202.116:8080/dna?seq1=seq1:ATGCATGCATGC&seq2=seq2:ATGCATGCATGC&minLength=3&stopOnFirst=false"

# Mostrar a pagina de status do LB
curl -s "http://54.247.202.116:8080/"








# PARTE 2: SCALING OUT

# Disparar 6 pedidos GrayScott XL ao mesmo tempo (para o LB escalar)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl -s -o /dev/null "http://54.247.202.116:8080/grayscott?size=512&maxIterations=1500&f=0.030&k=0.062&stopOnExtinction=false&seedMode=ring" &
done

# ir ao AWS Console dar refresh
# Novas instancias pending -> running
# Mostrar a pagina do LB a subir: Workers: 1 -> 2 -> 3...
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
    curl -s "http://54.247.202.116:8080/"
    sleep 5
done













# PARTE 3: LOAD BALANCING (~2 min)

# Confirmar que ha mais do que 1 worker
curl -s "http://54.247.202.116/"

# Descobrir os IPs publicos dos workers
aws ec2 describe-instances \
    --filters Name=tag:Project,Values=NatureAtCloud Name=tag:Role,Values=worker Name=instance-state-name,Values=running \
    --region eu-west-1 \
    --query "Reservations[*].Instances[*].[PublicIpAddress]" \
    --output text




# 2 JANELAS NO TERMINAL SECUNDARIO com SSH + top
# Janela 1: ssh -i ~/.ssh/cnv-keypair.pem ec2-user@<IP_DO_WORKER_1>
#           top
# Janela 2: ssh -i ~/.ssh/cnv-keypair.pem ec2-user@<IP_DO_WORKER_2>
#           top

# Com o top visivel nas duas janelas, mandar mais carga
curl -s -o /dev/null "http://54.247.202.116/grayscott?size=256&maxIterations=5000&f=0.030&k=0.062&stopOnExtinction=false&seedMode=ring" &
curl -s -o /dev/null "http://54.247.202.116/fractals?w=800&h=800&iterations=1000" &
curl -s -o /dev/null "http://54.247.202.116/grayscott?size=256&maxIterations=5000&f=0.030&k=0.062&stopOnExtinction=false&seedMode=stripe" &


# Mostrar o CPU a disparar nos 2 workers ao mesmo tempo















# PARTE 4: SCALING IN (~3 min)

# Parar tudo e esperar que o sistema escale para baixo

# Ir ao AWS Console dar refresh 
# os workers vao desaparecer
# running -> shutting-down -> terminated

for i in 1 2 3 4 5 6 7 8; do
    sleep 20
    curl -s "http://54.247.202.116/"
done













# PARTE 5: METRICS (~1 min)

# Mostrar DynamoDB no AWS Console
# (DynamoDB -> cnv-metrics -> Explore items)

aws dynamodb scan --table-name cnv-metrics --select COUNT --region eu-west-1 --query Count --output text

#Exemplo de 2 items
aws dynamodb scan --table-name cnv-metrics --limit 2 --region eu-west-1 --output json

#logs do LB (estimativas + scale up/down)
ssh -i ~/.ssh/cnv-keypair.pem ec2-user@54.247.202.116 'grep -E "(Complexity|SCALE)" /opt/cnv/lb.log | tail -20'

# Finish
# ./99-cleanup.sh 