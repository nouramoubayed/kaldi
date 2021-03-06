#!/bin/bash -u

. ./cmd.sh
. ./path.sh

# SDM - Signle Distant Microphone
micid=1 #which mic from array should be used?
mic=sdm$micid

stage=0
. utils/parse_options.sh

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail
set -x

# Path where AMI gets downloaded (or where locally available):
[ ! -r conf/ami_dir ] && echo "Please, run 'run_prepare_shared.sh' first!" && exit 1
AMI_DIR=$(cat conf/ami_dir)

final_lm=`cat data/local/lm/final_lm`
LM=$final_lm.pr1-7

# Download AMI corpus (distant channels), You need arount 130GB of free space to get whole data ihm+mdm,
if [ $stage -le 0 ]; then
  [ -e data/local/downloads/wget_sdm.sh ] && \
    echo "$data/local/downloads/wget_sdm.sh already exists, better quit than re-download... (use --stage N)" && \
    exit 1
  local/ami_download.sh --mics $micid sdm $AMI_DIR
fi

# Prepare mdm data directories,
if [ $stage -le 2 ]; then
  local/ami_sdm_data_prep.sh $AMI_DIR $micid
  local/ami_sdm_scoring_data_prep.sh $AMI_DIR $micid dev
  local/ami_sdm_scoring_data_prep.sh $AMI_DIR $micid eval
fi
# Here starts the normal recipe, which is mostly shared across mic scenarios,
# - for ihm we adapt to speaker by fMLLR,
# - for sdm and mdm we do not adapt for speaker, but for environment only (cmn),

# Feature extraction,
if [ $stage -le 3 ]; then
  for dset in train dev eval; do
    steps/make_mfcc.sh --nj 15 --cmd "$train_cmd" data/$mic/$dset data/$mic/$dset/log data/$mic/$dset/data
    steps/compute_cmvn_stats.sh data/$mic/$dset data/$mic/$dset/log data/$mic/$dset/data
  done
  for dset in train eval dev; do utils/fix_data_dir.sh data/$mic/$dset; done
fi

if [ $stage -le 4 ]; then
  # Taking a subset, now unused, can be handy for quick experiments,
  # Full set 77h, reduced set 9.5h,
  local/remove_dup_utts.sh 20 data/$mic/train data/$mic/train_nodup # remvove uh-huh,
  utils/subset_data_dir.sh --shortest data/$mic/train_nodup 30000 data/$mic/train_30k
fi

# Train systems,
nj=30 # number of parallel jobs,
nj_dev=$(cat data/$mic/dev/spk2utt | wc -l)
nj_eval=$(cat data/$mic/eval/spk2utt | wc -l)

if [ $stage -le 5 ]; then
  # Mono,
  steps/train_mono.sh --nj $nj --cmd "$train_cmd" --cmvn-opts "--norm-means=true --norm-vars=false" \
    data/$mic/train data/lang exp/$mic/mono
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/mono exp/$mic/mono_ali

  # Deltas,
  steps/train_deltas.sh --cmd "$train_cmd" --cmvn-opts "--norm-means=true --norm-vars=false" \
    5000 80000 data/$mic/train data/lang exp/$mic/mono_ali exp/$mic/tri1
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri1 exp/$mic/tri1_ali
fi

if [ $stage -le 6 ]; then
  # Deltas again, (full train-set),
  steps/train_deltas.sh --cmd "$train_cmd" --cmvn-opts "--norm-means=true --norm-vars=false" \
    5000 80000 data/$mic/train data/lang exp/$mic/tri1_ali exp/$mic/tri2a
  steps/align_si.sh --nj $nj --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri2a exp/$mic/tri2_ali
  # Decode,
  graph_dir=exp/$mic/tri2a/graph_${LM}
  $highmem_cmd $graph_dir/mkgraph.log \
    utils/mkgraph.sh data/lang_${LM} exp/$mic/tri2a $graph_dir
  steps/decode.sh --nj $nj_dev --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/dev exp/$mic/tri2a/decode_dev_${LM}
  steps/decode.sh --nj $nj_eval --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/eval exp/$mic/tri2a/decode_eval_${LM}
fi

# THE TARGET LDA+MLLT+SAT+BMMI PART GOES HERE:

if [ $stage -le 7 ]; then
  # Train tri3a, which is LDA+MLLT,
  steps/train_lda_mllt.sh --cmd "$train_cmd" \
    --splice-opts "--left-context=3 --right-context=3" \
    5000 80000 data/$mic/train data/lang exp/$mic/tri2_ali exp/$mic/tri3a
  # Decode,
  graph_dir=exp/$mic/tri3a/graph_${LM}
  $highmem_cmd $graph_dir/mkgraph.log \
    utils/mkgraph.sh data/lang_${LM} exp/$mic/tri3a $graph_dir
  steps/decode.sh --nj $nj_dev --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/dev exp/$mic/tri3a/decode_dev_${LM}
  steps/decode.sh --nj $nj_eval --cmd "$decode_cmd" --config conf/decode.conf \
    $graph_dir data/$mic/eval exp/$mic/tri3a/decode_eval_${LM}
fi

# skip SAT, and build MMI models
nj_mmi=80
if [ $stage -le 8 ]; then
  steps/align_si.sh --nj $nj_mmi --cmd "$train_cmd" \
    data/$mic/train data/lang exp/$mic/tri3a exp/$mic/tri3a_ali
fi

# At this point you can already run the DNN script:
# local/nnet/run_dnn_lda_mllt.sh
# exit 0

if [ $stage -le 9 ]; then
  steps/make_denlats.sh --nj $nj_mmi --cmd "$decode_cmd" --config conf/decode.conf \
      data/$mic/train data/lang exp/$mic/tri3a exp/$mic/tri3a_denlats
fi

# 4 iterations of MMI seems to work well overall. The number of iterations is
# used as an explicit argument even though train_mmi.sh will use 4 iterations by
# default.
if [ $stage -le 10 ]; then
  num_mmi_iters=4
  steps/train_mmi.sh --cmd "$train_cmd" --boost 0.1 --num-iters $num_mmi_iters \
    data/$mic/train data/lang exp/$mic/tri3a_ali exp/$mic/tri3a_denlats \
    exp/$mic/tri3a_mmi_b0.1
fi
if [ $stage -le 11 ]; then
  # Decode,
  graph_dir=exp/$mic/tri3a/graph_${LM}
  for i in 4 3 2 1; do
    decode_dir=exp/$mic/tri3a_mmi_b0.1/decode_dev_${i}.mdl_${LM}
    steps/decode.sh --nj $nj_dev --cmd "$decode_cmd" --config conf/decode.conf \
      --iter $i $graph_dir data/$mic/dev $decode_dir
    decode_dir=exp/$mic/tri3a_mmi_b0.1/decode_eval_${i}.mdl_${LM}
    steps/decode.sh --nj $nj_eval --cmd "$decode_cmd" --config conf/decode.conf \
      --iter $i $graph_dir data/$mic/eval $decode_dir
  done
fi

# DNN training. This script is based on egs/swbd/s5b/local/run_dnn.sh
# Some of them would be out of date.
if [ $stage -le 12 ]; then
  local/nnet/run_dnn_lda_mllt.sh $mic
fi

# TDNN training.
if [ $stage -le 13 ]; then
  local/online/run_nnet2_ms_perturbed.sh \
    --mic $mic \
    --hidden-dim 850 \
    --splice-indexes "layer0/-2:-1:0:1:2 layer1/-1:2 layer2/-3:3 layer3/-7:2 layer4/-3:3" \
    --use-sat-alignments false

  local/online/run_nnet2_ms_sp_disc.sh  \
    --mic $mic  \
    --gmm-dir exp/$mic/tri3a \
    --srcdir exp/$mic/nnet2_online/nnet_ms_sp
fi

#TDNN training
if [ $stage -le 14 ]; then
  local/nnet3/run_tdnn.sh \
    --mic $mic \
    --speed-perturb true \
    --stage 9 \
    --use-sat-alignments false
fi
exit 1;

#LSTM training
if [ $stage -le 15 ]; then
  local/nnet3/run_lstm.sh \
    --mic $mic \
    --train-stage -5 \
    --speed-perturb true \
    --use-sat-alignments false
fi

echo "Done."


# By default we do not build systems adapted to sessions for AMI in distant scnearios
# as this does not help a lot (around 1%), but one can do this by running below code:
exit;

# Train tri4a, which is LDA+MLLT+SAT,
steps/align_fmllr.sh --nj $nj --cmd "$train_cmd" \
  data/$mic/train data/lang exp/$mic/tri3a exp/$mic/tri3a_ali-fmllr

steps/train_sat.sh  --cmd "$train_cmd" \
  5000 80000 data/$mic/train data/lang exp/$mic/tri3a_ali-fmllr exp/$mic/tri4a

# Decode,
graph_dir=exp/$mic/tri4a/graph_${LM}
$highmem_cmd $graph_dir/mkgraph.log \
  utils/mkgraph.sh data/lang_${LM} exp/$mic/tri4a $graph_dir
steps/decode_fmllr.sh --nj $nj_dev --cmd "$decode_cmd" --config conf/decode.conf \
  $graph_dir data/$mic/dev exp/$mic/tri4a/decode_dev_${LM}
steps/decode_fmllr.sh --nj $nj_eval --cmd "$decode_cmd" --config conf/decode.conf \
  $graph_dir data/$mic/eval exp/$mic/tri4a/decode_eval_${LM}

