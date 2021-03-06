#' Wrapper function for breakpointR
#'
#' This script will move through .bam files in a folder and perform several steps (see Details).
#'
#' 1. calculate deltaWs chromosome-by-chromsome
#' 2. localize breaks that pass zlim above the threshold
#' 3. genotype both sides of breaks to confirm whether strand state changes
#' 4. write a file of _reads, _deltaWs and _breaks in a chr fold -> can upload on to UCSC Genome browser
#' 5. write a file for each index with all chromosomes included -> can upload on to UCSC Genome browser
#'
#' @param input.data A file with aligned reads in BAM format.
#' @param pairedEndReads Set to \code{TRUE} if you have paired-end reads in your file.
#' @param chromosomes If only a subset of the chromosomes should be processed, specify them here.
#' @param windowsize The window size used to calculate deltaWs, either an integer or 'scale'.
#' @param trim The amount of outliers in deltaWs removed to calculate the stdev (10 will remove top 10\% and bottom 10\% of deltaWs).
#' @param peakTh The treshold that the peak deltaWs must pass to be considered a breakpoint.
#' @param zlim The number of stdev that the deltaW must pass the peakTh (ensures only significantly higher peaks are considered).
#' @param bg The amount of background introduced into the genotype test.
#' @param minReads The minimum number of reads required for genotyping.
#' @param maskRegions List of regions to be excluded from the analysis (format: chromosomes start end)
#' @author Ashley Sanders, David Porubsky, Aaron Taudt
#' @export

runBreakpointr <- function(input.data, pairedEndReads=TRUE, chromosomes=NULL, windowsize=1000000, scaleWindowSize=T, trim=10, peakTh=0.33, zlim=3.291, bg=0.02, min.mapq=10, pair2frgm=FALSE, minReads=20, maskRegions=NULL) {

	## check the class of the input data, make GRanges object of file
	if ( class(input.data) != "GRanges" ) {
		suppressWarnings( fragments <- bam2GRanges(input.data, pairedEndReads=pairedEndReads, chromosomes=chromosomes, keep.duplicate.reads=FALSE, min.mapq=min.mapq, pair2frgm=pair2frgm) )
	} else {
		fragments <- input.data
		input.data <- 'CompositeFile'
	}

	filename <- basename(input.data)
	message("Working on ", filename)
	
	if (scaleWindowSize==F) {
		reads.per.window <- windowsize
		message("  Calculating deltaWs")
		dw <- deltaWCalculator(fragments, reads.per.window=reads.per.window)
	}
	
	## remove reads from maskRegions
	if (!is.null(maskRegions)) {
		#mask.df <- read.table(maskRegions, header=F, sep="\t", stringsAsFactors=F)
		#if (any(mask.df$V1 %in% chromosomes)) {
		#	mask.df <- mask.df[mask.df$V1 %in% chromosomes,] #select only chromosomes submited for analysis
		#	mask.gr <- GenomicRanges::GRanges(seqnames=mask.df$V1, IRanges(start=mask.df$V2, end=mask.df$V3))
			#mask <- findOverlaps(mask.gr, fragments)
			mask <- findOverlaps(maskRegions, fragments)
			fragments <- fragments[-subjectHits(mask)]			
		#} else {
		#	warning(paste0('Skipping maskRegions. Chromosomes names conflict: ', mask.df$V1[1], ' not equal ',chromosomes[1]))
		#}	
	} 

	reads.all.chroms <- GenomicRanges::GRangesList()
	reads.all.chroms <- fragments

	deltas.all.chroms <- GenomicRanges::GRangesList()
	breaks.all.chroms <- GenomicRanges::GRangesList()
	counts.all.chroms <- GenomicRanges::GRangesList()
	for (chr in unique(seqnames(fragments))) {
		message("  Working on chromosome ",chr)
		fragments.chr <- fragments[seqnames(fragments)==chr]
		fragments.chr <- keepSeqlevels(fragments.chr, chr)

		message("    calculating deltaWs")
		if (scaleWindowSize==T) {
			## normalize only for size of the chromosome 1
			#reads.per.window <- max(10, round(windowsize/(seqlengths(fragments)[1]/seqlengths(fragments)[chr]))) # scales the bin to chr size, anchored to chr1 (249250621 bp)
			
			## normalize for size of chromosome one and for read counts of each chromosome
			tiles <- unlist(tileGenome(seqlengths(fragments)[chr], tilewidth = windowsize))
			counts <- countOverlaps(tiles, fragments.chr)
			reads.per.window <- max(10, round(mean(counts[counts>0], trim=0.05)))
		
			dw <- deltaWCalculator(fragments.chr, reads.per.window=reads.per.window)
		}
		deltaWs <- dw[seqnames(dw)==chr]

		message("    finding breakpoints")
		breaks<- suppressMessages( breakSeekr(deltaWs, trim=trim, peakTh=peakTh, zlim=zlim) )

		## Genotyping
		if (length(breaks) >0 ) {
			maxiter <- 10
			iter <- 1
			message("    genotyping ",iter)
			flush.console()
			newBreaks <- GenotypeBreaks(breaks, fragments, backG=bg, minReads=minReads)
			prev.breaks <- breaks	
			breaks <- newBreaks
			while (length(prev.breaks) > length(newBreaks) && !is.null(breaks) ) {
				flush.console()
				iter <- iter + 1
				message("    genotyping ",iter)	
				newBreaks <- GenotypeBreaks(breaks, fragments, backG=bg, minReads=minReads)
				prev.breaks <- breaks	
				breaks <- newBreaks
				if (iter == maxiter) { break }
			}
		} else {
			newBreaks<-NULL # assigns something to newBreaks if no peaks found
		}

		### count reads between the breaks and write into GRanges
		if (is.null(newBreaks)) {
			
			Ws <- length(which(as.logical(strand(fragments.chr) == '-')))
			Cs <- length(which(as.logical(strand(fragments.chr) == '+')))
			chrRange <- GRanges(seqnames=chr, ranges=IRanges(start=1, end=seqlengths(fragments.chr)[chr]))
			counts <- cbind(Ws,Cs)
			mcols(chrRange) <- counts
			seqlengths(chrRange) <- seqlengths(fragments.chr)[chr]

			## genotype entire chromosome
			WC.ratio <- (chrRange$Ws-chrRange$Cs)/sum(c(chrRange$Ws,chrRange$Cs))
			if (WC.ratio > 0.8) {
				state <- 'ww'
			} else if (WC.ratio < -0.8) {
				state <- 'cc'
			} else if (WC.ratio < 0.2 & WC.ratio > -0.2) {
				state <- 'wc'
			} else {
				state <- '?'
			}					
			chrRange$states <- state
			suppressWarnings( counts.all.chroms[[chr]] <- chrRange )
	
		} else {
			
			breaks.strand <- newBreaks
			strand(breaks.strand) <- '*'
			breakrange <- gaps(breaks.strand)
			breakrange <- breakrange[strand(breakrange)=='*']

			## pull out reads of each line, and genotype in the fragments
			strand(breakrange) <- '-'
			Ws <- GenomicRanges::countOverlaps(breakrange, fragments)
			strand(breakrange) <- '+'
			Cs <- GenomicRanges::countOverlaps(breakrange, fragments)
			strand(breakrange) <- '*'

			## pull out states for each region between the breakpoints
			concat.states <- paste(newBreaks$genoT, collapse="-")
			split.states <- unlist(strsplit(concat.states, "-"))
			states.idx <- seq(from=1,to=length(split.states), by=2)
			states.idx <- c(states.idx, length(split.states))
			states <- split.states[states.idx]

			counts <- cbind(Ws,Cs)
			mcols(breakrange) <- counts
			breakrange$states <- states
			suppressWarnings( counts.all.chroms[[chr]] <- breakrange )
		}

		### write breaks and deltas into GRanges
		if (length(deltaWs) > 0) {
			suppressWarnings( deltas.all.chroms[[chr]] <- deltaWs[,'deltaW'] )  #select only deltaW metadata column to store
		}
		if (length(newBreaks) > 0) {
			suppressWarnings( breaks.all.chroms[[chr]] <- newBreaks )
		}
		
	}
	## creating list of list where filename is first level list ID and deltas, breaks and counts are second list IDs
	reads.all.chroms <- unlist(reads.all.chroms)	
	deltas.all.chroms <- unlist(deltas.all.chroms)
	breaks.all.chroms <- unlist(breaks.all.chroms)
	counts.all.chroms <- unlist(counts.all.chroms)
	names(reads.all.chroms) <- NULL
	names(deltas.all.chroms) <- NULL
	names(breaks.all.chroms) <- NULL
	names(counts.all.chroms) <- NULL
	
	## save set parameters for future reference
	parameters <- c(windowsize=windowsize, scaleWindowSize=scaleWindowSize, trim=trim, peakTh=peakTh, zlim=zlim, bg=bg, minReads=minReads)

	data.obj <- list(fragments=fragments, deltas=deltas.all.chroms, breaks=breaks.all.chroms, counts=counts.all.chroms, params=parameters)

	return(data.obj)
}

