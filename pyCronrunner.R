################################################################################
## Definitions
################################################################################
source("~/prefix.R")
setwd("~/mz/baselinesForDAU_forPeter/")
library(mozaws)
islocaltolaptopq <-   grepl("darwin",R.version['platform'])
spark.rhipe <- function(cl){
    cl  <- aws.step.run(cl, script=sprintf('s3://%s/run.user.script.sh',aws.options()$s3bucket)
                      , args="https://raw.githubusercontent.com/saptarshiguha/mozaws/master/bootscriptsAndR/setupRhipe.sh"
                      , name="Install RHIPE"
                      , wait=60)
}
spark.init <- function(cl){
    cl  <- aws.step.run(cl, script=sprintf('s3://%s/run.user.script.sh',aws.options()$s3bucket)
                      , args="https://raw.githubusercontent.com/saptarshiguha/mozillametricstools/master/common/spark.init.step.sh"
                      , name="Clone Our Repo"
                      , wait=60)
}

.Last <- function(){
    tryCatch(aws.kill(runOb$cl()),error=function(e) NULL)
    tryCatch(aws.kill(CL),error=function(e) NULL)
    print("Killing Spark")    
}

isn <- function(a,r=NA) if( length(a)==0 || is.null(a)) r else a
CL <- NULL


## ##############################################################################
## Initialize
## ##############################################################################
aws.init(ec2key="20161025-dataops-dev"
        ,localpubkey = "~/mz/awsssh.pub"
        ,opts = list(loguri    = "s3://mozilla-metrics/share/logs/"
                    ,s3bucket  = "mozilla-metrics/share/bootscriptsAndR"
                    ,timeout   = as.character(as.integer(5*60))
                    ,ec2attributes = "InstanceProfile='telemetry-spark-cloudformation-TelemetrySparkInstanceProfile-1SATUBVEXG7E3'"
                    ,configfile ="https://s3-us-west-2.amazonaws.com/telemetry-spark-emr-2/configuration/configuration.json"
                     ))
invisible(aws.options(releaselabel="emr-5.4.0"))


makePyRunner <- function(ProjName, URL,NumNodes=10, Spot=0.8,cl=NULL){
    URLTOPYCODE <- URL; JNAME <- ProjName; NNODES=NumNodes ; SPOT=Spot
    ## #######################################################
    ## The shell code that downloads your program and runs it
    ## if you test this in CLI,do
    ## unset PYSPARK_DRIVER_PYTHON else spark-submit will not
    ## work
    ## #######################################################
    mcl <- NULL;stepid <- NULL
    init <- function(){
        runner <- sprintf("#!/bin/sh
#source /home/hadoop/.bashrc
unset PYSPARK_DRIVER_PYTHON
export PYSPARK_PYTHON=/mnt/anaconda2/bin/python
curl  -o /tmp/code.py %s
/usr/lib/spark/bin/spark-submit /tmp/code.py
echo 'completed'
exit 0
", URLTOPYCODE)
        ## ######################################################################
        ## upload this shell code to a unique name and use this in the step run
        ## we could place it on http site rather than s3
        ## ######################################################################
        x <- tempfile()
        writeLines(runner,x)
        cat(sprintf("Creating temporary file with contents: %s\n",x))
        cat(sprintf("Uploading %s to s3://mozilla-metrics/user/sguha/tmp/runXPDB%s.sh",x,JNAME))
        system(sprintf("aws s3 cp %s  s3://mozilla-metrics/user/sguha/tmp/runXPDB%s.sh",x,JNAME))
        if(is.null(cl)){
            cl <- aws.clus.create(workers=1,spark=TRUE,ver=TRUE,applications=c("Spark","Hive","Hadoop"),name = JNAME,wait=30)
            CL <<- cl
            if(!identical("WAITING",cl$Status$State)){
                quit(save='yes')
            }
            ## ##############################################################################
            ## Grow Cluster, Add R packages etc
            ## ##############################################################################
            cat("Running the Step to add mozillametricstools code\n")
            spark.init(cl);spark.rhipe(cl);
            cl <- aws.modify.groups(cl, NNODES, spot = SPOT)
            while(TRUE){
                cl <- aws.clus.info(cl)
                ig <- Filter(function(s) !is.null(s$BidPrice),cl$InstanceGroups)
                if(length(ig)>0 && ig[[1]]$RunningInstanceCount>=NNODES/2) break
                if(length(ig)>0) print(sprintf("Sleeping, since count of group is: %s",ig[[1]]$RunningInstanceCount))
                Sys.sleep(45)
            }
            print("Groups resized")
        }else{
            print(sprintf("Using the cluster you provided\n"))
        }
        print(cl)
        mcl <<- cl
    }

    copyLogs <- function(ID=NULL){
        if(is.null(ID)) ID <- stepid
        if(is.null(ID)) stop("ID is missing")
        zipper <- sprintf(" cd /mnt/var/log/hadoop/steps/%s && tar cvfz /tmp/mylog-%s.tar.gz . && aws s3 cp /tmp/mylog-%s.tar.gz   s3://mozilla-metrics/user/sguha/tmp/", ID,JNAME, JNAME)
        dns <- isn(mcl$MasterPublicDnsName)
        trn <- infuse("ssh   -o StrictHostKeyChecking=no  -i {{pathtopriv}}  hadoop@{{dns}} '{{cmd}}'", pathtopriv = aws.options()$pathtoprivkey,dns=dns, cmd=zipper)
        system(trn)
    }
    stepRun <- function(){
    ## ##############################################################################
    ## Run the Step
    ## ##############################################################################
        cat("Running the Step \n")
        print(mcl)
        tryCatch({
            mcl  <<- aws.step.run(mcl, script=sprintf('s3://%s/run.user.script.sh',aws.options()$s3bucket)
                              , args=sprintf("s3://mozilla-metrics/user/sguha/tmp/runXPDB%s.sh",JNAME)
                              , name=sprintf("Running %s",JNAME)
                              , wait=TRUE)
            stepPassed <- TRUE
        },error=function(e){
            stepPassed <- FALSE
        })
        mcl <<- aws.clus.info(mcl)
        codeStep <- tryCatch(Filter(function(s) grepl(JNAME,s$Name),mcl$steps)[[1]],error=function(e) NULL)
        stepid <<- codeStep$Id
        list(step=codeStep,id=codeStep$Id)
    }
    getcl <- function(){
        return(mcl)
    }
    x <- function(){
        a <- list(stepRun=stepRun, copyLogs=copyLogs,init=init,cl=getcl)
        return(a)
    }
    x()
}

################################################################################
## Run the code
################################################################################

cl <- NULL
runOb <- makePyRunner(
    ProjName = 'FXBASELINE',
    URL = 'https://gist.githubusercontent.com/saptarshiguha/2263ee339c51395858a5290ec7bfa209/raw/cd5cd658adfa497f44f1deff2e01c06fdf891afc/css_classes.py'
    ,NumNode=35,Spot=0.8,cl=cl)

runOb$init()
print("initialized over")
x <- runOb$stepRun()
runOb$copyLogs()

################################################################################
## My steps
################################################################################
## library(rmarkdown)
## setwd("~/mz/baselinesForDAU_forPeter/")
## render("code.2.Rmd")
## system("cp code.2.html /tmp/AverageDAU_WoW.html && scp /tmp/AverageDAU_WoW.html db1:~/protected/sguha/")
source("./code.3.R")
system("cd web && python bkh2.py")
system("cd web && scp index.html db1:~/protected/sguha/adibaseline/")
tryCatch(aws.kill(runOb$cl()),error=function(e) NULL)
tryCatch(aws.kill(CL),error=function(e) NULL)