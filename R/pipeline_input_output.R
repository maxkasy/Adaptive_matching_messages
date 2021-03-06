library(dplyr)
library(readr)
library(gert) # for git
# https://github.com/r-lib/gert

# The following is necessary for making parallel MCMC work in RStudio
parallel:::setDefaultClusterOptions(setup_strategy = "sequential")

# sourcing code for simulating from posterior and calculating optimal matching
source("matching_functions.R")

# number of types
k=4 

# type codes to construct types U and V
type_codes = tibble(
    gender = c("F","F","M","M"),
    age = c("YOUNG", "OLD","YOUNG", "OLD"),
    string = c("woman under 30 years old", "woman over 50 years old", "man under 30 years old", "man over 50 years old"),
    U= 1:4,
    V=1:4
)



# clear out all the Qualtrics input files, for a clean slate
clear_subfolders = function(path="../Pipeline/Qualtrics_input/"){
    filelist=list.files(path, recursive=T)
    
    walk(paste(path, filelist, sep=""),
         file.remove)
}


# commit and push all files in Qualtrics_input folder to Github
update_github = function(repo = "../") {
    git_add(files = "*", repo = repo)
    
    git_commit(repo = repo,
               message = paste0("Update: ", Sys.time()))
    
    # this uses my stored ssh key
    git_push(repo = repo)
}


# Function to create the match and assignment for the first wave senders
matching_uniform = function(wave) {
    tibble(U = factor(rep(1:k, length.out = k^2, each=k), levels=1:k),
           V = factor(rep(1:k, length.out = k^2), levels=1:k),
           index_U = 4*(wave-1) + rep(1:k, length.out = k^2),
           index_V = 4*(wave-1) + rep(1:k, length.out = k^2, each=k)) %>% 
        write_csv(paste("../Pipeline/Match_files/", wave, "_matching.csv", sep = "" ))
}

# read in qualtrics output files and merge them into consolidated and cleaned file
prior_data_senders_merge = function(wave) {
    output_filenames = list.files("../Pipeline/Qualtrics_output/Senders/")
    
    output_filepaths = paste("../Pipeline/Qualtrics_output/Senders/", 
                             output_filenames , sep="")
    
    # Reading in all files in output folder 
    qualtrics_output = output_filepaths %>% 
        map(read_csv) %>% 
        map(~ slice(.x, 3:6)) # dropping the first 2 rows, and all but the first 4 observations
    
    # create variables with source filename, gender, age, side of match
    for (i in 1:length(output_filenames)) {
        qualtrics_output[[i]]$sourcefile = output_filenames[i]
        qualtrics_output[[i]]$gender = substr(output_filenames[i],1,1)
        qualtrics_output[[i]]$age = ifelse(substr(output_filenames[i],3,3)=="Y",
                                           "YOUNG", "OLD")
    }
    
    # export merged senders file  
    qualtrics_output %>%         
        bind_rows() %>% 
        left_join(type_codes,by = c("gender", "age")) %>% # merge in type to construct U and V 
        write_csv(paste("../Pipeline/Match_files/", wave, 
                        "_merged_processed_output_senders", ".csv", sep = "" ))  
}




# read in qualtrics output files and merge them into consolidated and cleaned file
prior_data_recipients_merge = function(wave) {
    output_filenames = list.files("../Pipeline/Qualtrics_output/Receivers/")
    
    output_filepaths = paste("../Pipeline/Qualtrics_output/Receivers/", 
                             output_filenames , sep="")
    
    # Reading in all files in output folder 
    qualtrics_output = output_filepaths %>% 
        map(read_csv) %>% 
        map(~ slice(.x, 3:6)) # dropping the first 2 rows, and all but the first 4 observations
    
    # create variables with source filename, gender, age, side of match
    for (i in 1:length(output_filenames)) {
        qualtrics_output[[i]]$sourcefile = output_filenames[i]
        qualtrics_output[[i]]$gender = substr(output_filenames[i],1,1)
        qualtrics_output[[i]]$age = ifelse(substr(output_filenames[i],3,3)=="Y",
                                           "YOUNG", "OLD")
    }
    
    qualtrics_output_recipient = 
        qualtrics_output %>% 
        bind_rows() %>% 
        left_join(type_codes,by = c("gender", "age")) %>%  # merge in type to construct V %>% 
        select(-U) %>% 
        mutate(ID = as.numeric(ID), U=as.numeric(NA), index_U=as.numeric(NA))

    #merge in matching by recipient ID and recipient type
    for (w in 1:wave) {
        matching = read_csv(paste("../Pipeline/Match_files/", w, "_matching.csv", sep = "" )) %>% 
            rename(ID = index_V, U_new=U, index_U_new=index_U)
        qualtrics_output_recipient = qualtrics_output_recipient %>% 
            left_join(matching, by = c("V", "ID")) %>% 
            mutate(U= if_else(!is.na(U_new), U_new, U),
                   index_U= if_else(!is.na(index_U_new), index_U_new, index_U)) %>% 
            select(-U_new, -index_U_new)
    }
    
    # calculate outcome variable as sum of scores for recipients
    Y=qualtrics_output_recipient %>% 
        select(paste("Q", 101:113, sep=""))%>% 
        sapply(as.numeric) %>% 
        rowSums() 
    
    # export merged recipients file    
    qualtrics_output_recipient %>% 
        mutate(Y=Y) %>% 
        write_csv(paste("../Pipeline/Match_files/", wave, 
                        "_merged_processed_output_recipients", ".csv", sep = "" ))  
    
}



# read in prior data, run Thompson sampling, and store result in daily match file
prior_data_to_matching = function(wave){
    prior_data_path = paste("../Pipeline/Match_files/", wave, 
                            "_merged_processed_output_recipients", ".csv", sep = "" )

    # read in prior outcome data
    prior_data = read_csv(prior_data_path) %>% 
        mutate(U=factor(U, levels=1:k), 
               V=factor(V, levels=1:k))
    
    # generate types for new wave
    U= tibble(U=factor(rep(1:k, length.out = k^2), levels=1:k),
              index_U = (wave)*k + rep(1:k, each=k))
    V= tibble(V=factor(rep(1:k, length.out = k^2), levels=1:k),
              index_V = (wave)*k + rep(1:k, each=k))
    
    # calculate thompson matching for the next wave
    best_matching = thompson_matching(prior_data, U, V)
    
    # write to dated file with new matching
    write_csv(best_matching$matching,
              paste("../Pipeline/Match_files/", wave+1, "_matching.csv", sep = "" ))
    
    # print figures of current estimates and sample averages
    sample_averages = prior_data %>% 
        group_by(U,V) %>% 
        summarise(ybar = mean(Y)/(4*13)) %>% 
        ungroup() %>% 
        mutate(yhat=plogis(best_matching$beta_hat))
    
    write_csv(sample_averages,
              paste("../Pipeline/Figures/", wave, "_estimates.csv", sep = "" ))
  
    p1=plot_prediction_matrix(best_matching$beta_hat,
                              k1=k, k2=k,
                              title = "Estimated parameters")
    p2=plot_prediction_matrix(qlogis(sample_averages$ybar),
                              k1=k, k2=k,
                              title = "Sample average outcomes")
    ggsave(paste("../Pipeline/Figures/", wave, "_estimates.pdf", sep = "" ),
            (p1 | p2),
            width=7, height=4)
}



# read in daily match file, export recipient types to sender folders
# index is current running index for Qualtrics for each of the 4 types 
matching_to_sender_surveys = function(wave){
    matching = paste("../Pipeline/Match_files/", wave, 
                     "_matching.csv", sep = "" ) %>% 
        read_csv() %>% 
        left_join(type_codes[-c(3,5)],by = "U") %>%  # merge in sender characteristics for sender path
        left_join(type_codes[c(3,5)], by = "V") # merge in recipient characteristics for survey content
    
    for (i in 1:nrow(matching)) {
        sender_path = paste("../Pipeline/Qualtrics_input/", 
                            matching[i, "gender"], "-",
                            matching[i, "age"],
                            "-S/", sep="")
   
        write(matching[[i,"string"]], 
              paste(sender_path, matching[[i, "index_U"]], "_recipient.txt", sep=""))
    }
}


# read in message file, export sender types and messages to recipient folders
messages_to_recipient_surveys = function(wave){
    # read in compiled data from senders
    merged_processed_output_senders =
        read_csv(paste("../Pipeline/Match_files/", wave,
                       "_merged_processed_output_senders", ".csv", sep = "" ))
    
    matching = paste("../Pipeline/Match_files/", wave, 
                     "_matching.csv", sep = "" ) %>% 
        read_csv() %>% 
        left_join(type_codes[-c(3,4)],by = "V") %>%  # merge in recipient characteristics for recipient path
        left_join(type_codes[c(3,4)], by = "U") # merge in sender characteristics for survey content
    
    for (i in 1:nrow(matching)) {
        recipient_path = paste("../Pipeline/Qualtrics_input/", 
                               matching[i, "gender"], "-",
                               matching[i, "age"],
                               "-R/", sep="")
        
        write(matching[[i,"string"]], 
              paste(recipient_path, matching[[i, "index_V"]], "_sender.txt", sep=""))
        
        message_row =
            merged_processed_output_senders %>% 
            filter(ID == matching[[i, "index_U"]],
                   U == matching[[i, "U"]]) %>% 
            slice(1)
        
        if (nrow(message_row) >0) {
            write(message_row$message_final,
                  paste(recipient_path, matching[[i, "index_V"]], "_msg.txt", sep=""))
        }
    }
}



# Master functions for the two stages of each wave in the experiment
senders_to_recipients_master = function(wave) {
    prior_data_senders_merge(wave)
    messages_to_recipient_surveys(wave)
    update_github()
}

recipients_to_senders_master = function(wave) {
    prior_data_recipients_merge(wave)
    prior_data_to_matching(wave)
    matching_to_sender_surveys(wave+1)
    update_github()
}

