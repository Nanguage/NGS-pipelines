#!/usr/bin/env bash -e

set -e

function print_usage {
    cat <<EOF
usage:
$ rnaseq-pipe INPUT_DIR INDEX_PREFIX GTF
        [--aligner=bwa-aln/bwa-mem/bowtie2/[hisat2]]
        [-t/--threads=THREADS]
        [-s/--strandness=no/[fr]/rf]
        [-w/--workdir=WORKDIR[./]]
        [--pbs]

INPUT: 1. clean(trimmed) fastq.gz file
       2. index preifx for aligner
       3. gtf file

OUTPUT: 1. sorted bam file
        2. count tables for each sample
        3. bigwig file

NOTE: 1. fastq should named as _R1.fastq.gz _R2.fastq.gz
      2. This pipeline only for pair-end library
EOF
}


## PARSE ARG

# default arguments
aligner=hisat2 # bowtie2 / bwa-aln / bwa-mem / hisat2
strandness=fr
workdir="./"
threads=4
pbs=0 # `1` for use pbs system

if ! options=$(getopt -o t:s:w:a: --long threads:,aligner:,pbs:,strandness:,workdir -- "$@"); then
    exit 1
fi

set -- $options

while true ; do
    case "$1" in
        -a|--aligner)
            case "$2" in
                "") shift 2 ;;
                *) aligner=$2 ; shift 2 ;;
            esac ;;
        -t|--threads)
            case "$2" in
                "") shift 2 ;;
                *) threads=$2 ; shift 2 ;;
            esac ;;
        -s|--strandness)
            case "$2" in
                "") shift 2 ;;
                *) strandness=$2 ; shift 2 ;;
            esac ;;
        -w|--workdir)
            case "$2" in
                "") shift 2 ;;
                *) workdir=$2 ; shift 2 ;;
            esac ;;
        --pbs) pbs=1 ; shift ;;
        --) shift ; break ;;
        *) print_usage ; exit 1 ;;
    esac
done

if [ $# -ne 3 ]; then
    print_usage
    exit 1
fi

input_dir=$1
idx_prefix=$2
gtf=$3

# strip "'"
export input_dir=${input_dir//\'/}
export idx_prefix=${idx_prefix//\'/}
export gtf=${gtf//\'/}
export aligner=${aligner//\'/}
export strandness=${strandness//\'/}
export workdir=${workdir//\'/}
export threads=${threads//\'/}
export pbs=${pbs//\'/}

# convert all path to realpath
input_dir=$(realpath ${input_dir})
idx_prefix=$(realpath ${idx_prefix})
gtf=$(realpath ${gtf})
workdir=$(realpath ${workdir})

# print parameters
echo "start pipeline with parameters:"
echo "    INPUT_DIR: $input_dir"
echo "    INDEX_PREIFX: $idx_prefix"
echo "    GTF: $gtf"
echo "    aligner: $aligner"
echo "    strandness: $strandness"
echo "    workdir: $workdir"
echo "    threads: $threads"
echo "    pbs: $pbs"

## END PARSE ARG


if [ ! -d $input_dir ]; then
    echo "[error input dir not exist]"
    exit 1
fi


function align {

    # do [alignment] for pair end fastq.gz file,

    # usage: align ID INPUT_DIR ALIGNER INDEX_PREFIX STRANDNESS THREADS
    # INPUT: paired fastq.gz file (ID_R1.fastq.gz & ID_R2.fastq.gz)
    # OUTPUT: sam file(ID.sam)

    # support aligner:
    #   bwa
    #       aln (bwa-aln)
    #       mem (bwa-mem)
    #   bowtie2
    #   hisat2

    id=$1
    input_dir=$2
    aligner=$3
    idx_prefix=$4
    strandness=$5
    threads=$6

    echo "do alignment with" $aligner

    R1="$id"_R1.fastq
    R2="$id"_R2.fastq

    r1f=$input_dir/$R1.gz
    r2f=$input_dir/$R2.gz

    if [ "$aligner" == bwa* ]; then
        # aligner: bwa

        # bwa don't consider strand specific
        if [ $strandness != "no" ]; then
            echo "[warning] All bwa algorithms always map reads to both strands of the reference."
            echo "[warning] Setting strandness to 'no'"
            strandness="no"
        fi

        # decompress fiestly
        echo "decompressing ..."
        zcat $r1f > $R1 &
        zcat $r2f > $R2 &
        wait

        if [ "$aligner" == "bwa-aln" ]; then
            # bwa backtrack
            echo "alignment ..."
            bwa aln $idx_prefix -t $threads $R1 > "$id"_R1.sai
            bwa aln $idx_prefix -t $threads $R2 > "$id"_R2.sai

            echo "sai to sam ..."
            bwa sampe $idx_prefix "$id"_R1.sai "$id"_R2.sai $R1 $R2 > $id.sam
            rm "$id"_R1.sai
            rm "$id"_R2.sai
        elif [ "$aligner" == "bwa-mem" ]; then
            # bwa mem
            echo "alignment ..."
            bwa mem $idx_prefix $R1 $R2 -t $threads > $id.sam
        fi

        rm $R1 $R2 # remove ungziped file

    elif [ "$aligner" == "bowtie2" ]; then
        # aligner: bowtie2
        if [ ${strandness} != "rf" ]; then
            bowtie2 -x $idx_prefix -1 $r1f -2 $r2f -S $id.sam -p $threads --fr
        else
            bowtie2 -x $idx_prefix -1 $r1f -2 $r2f -S $id.sam -p $threads --rf
        fi

    elif [ "$aligner" == "hisat2" ]; then
        # aligner: hisat2
        if [ ${strandness} != "rf" ]; then
            hisat2 -x $idx_prefix -1 $r1f -2 $r2f -S $id.sam -p $threads --fr
        else
            hisat2 -x $idx_prefix -1 $r1f -2 $r2f -S $id.sam -p $threads --rf
        fi
    fi

    echo "done"
}


function process_sam {
    # convert [sam to bam]
    # [sort] bam
    # [index] bam

    # usage: process_sam ID THREADS
    # INPUT: sam file (ID.sam)
    # OUTPUT: sorted bam file(ID.sorted.bam) and it's index
    # NOTE: will remove sam and unsorted bam file

    id=$1
    threads=$2

    echo "samtools sort"
    samtools view -bh $id.sam -o $id.bam
    samtools sort -@ $threads $id.bam -o $id.sorted.bam
    samtools sort -n -@ $threads $id.bam -o $id.sorted.name.bam

    echo "[warning] remove sam and unsorted bam"
    rm $id.sam $id.bam
    samtools index -@ $threads $id.sorted.bam

}


function feature_count {
    # [count] reads mapped to genomic features
    
    # usage: feature_count ID GTF STRANDNESS
    # INPUT: bam file (ID.bam)
    # OUTPUT: gene count list(ID.count.txt)
    # NOTE: bam file should sorted by name

    id=$1
    gtf=$2
    strandness=$3

    echo "htseq count ${id}"
    if [ ${strandness} == "fr" ]; then
        htseq-count -s yes -r name -f bam $id.sorted.name.bam $gtf > $id.count.txt
    elif [ ${strandness} == "rf" ]; then
        htseq-count -s reverse -r name -f bam $id.sorted.name.bam $gtf > $id.count.txt
    else
        htseq-count -s no -r name -f bam $id.sorted.name.bam $gtf > $id.count.txt
    fi
}


export -f align
export -f process_sam


function pipe-front {
    # put all step together
    # pipe all processing steps of one data sample
    # run on shell front end

    # usage: pipe-front ID
    # OUTPUT: expression count file(ID.count.txt)
    # NOTE: stream stderr to ID.log

    id=$1

    echo "[alignment]" | tee -a $id.log
    align $id $input_dir $aligner $idx_prefix $strandness $threads 2>> $id.log

    echo "[processing sam]" | tee -a $id.log
    process_sam $id $threads 2>> $id.log

    echo "[generate bigwig file]" | tee -a $id.log
    bamCoverage -b $id.sorted.bam -o $id.bw 2>> $id.log

    echo "[htseq-count]" | tee -a $id.log
    feature_count $id $gtf $strandness 2>> $id.log
}


function pipe-pbs {
    # pbs cluster version pipeline

    # usage: pipe-pbs ID


    function qqsub {
        qsub -V -l nodes=1:ppn="$threads" -d $PWD $@
    }

    qid_align=$(echo "align $id $input_dir $aligner $idx_prefix $strandness $threads" | qqsub -N ALIGN_$id)

    qid_psam=$(echo "process_sam $id $threads" | qqsub -N PSAM_$id -W depend=afterok:$qid_align)

    qid_genbw=$(echo "bamCoverage -p $threads -b $id.sorted.bam -o $id.bw" | qqsub -N GENBW_$id -W depend=afterok:$qid_psam)

    qid_htc=$(echo "feature_count $id $gtf $strandness" | qsub -l nodes=1:ppn=1 -d $PWD -N HTC_$id -W depend=afterok:$qid_psam)

}


function main {

    if [ ! -d $workdir ]; then
        mkdir $workdir
    fi
    cd $workdir

    # deploy tasks of all samples
    # 

    for id in `ls $input_dir | grep fastq.gz | sed 's/.fastq.gz//g' | sed 's/_R1//' | sed 's/_R2//' | sort -u`;
    do
        echo sample id: $id
        if [ $pbs -eq 1 ]; then
            echo "launch pbs jobs."
            pipe-pbs $id
        else
            echo "run on front end."
            pipe-front $id
        fi
    done
}


main
